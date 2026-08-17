/**
 * Catalogue des fichiers du cadastre Etalab.
 *
 * Le code précédent scrapait les index HTML d'Apache avec BeautifulSoup, en
 * parsant les dates à la regex. Ça ne marche plus : le serveur renvoie
 * désormais des dates ISO 8601 (`2026-07-02T09:00:40.000Z`) là où la regex
 * attendait `02-Jul-2026 09:00`.
 *
 * Inutile de la réparer : les fichiers sont hébergés sur un bucket OVH qui
 * autorise le ListObjectsV2 ANONYME. On obtient directement Key, Size, ETag et
 * LastModified — soit exactement la détection de changement que les fichiers
 * JSON de suivi de l'ancienne version tentaient de reconstituer à la main.
 */

const BUCKET = 'https://cadastre.s3.rbx.io.cloud.ovh.net'
const ROOT = 'etalab-cadastre'

/** Les couches publiées par Etalab, par niveau d'agrégation. */
export type Couche =
  | 'communes'
  | 'parcelles'
  | 'sections'
  | 'feuilles'
  | 'batiments'
  | 'lieux_dits'
  | 'prefixes_sections'
  | 'subdivisions_fiscales'

export interface ObjetS3 {
  key: string
  size: number
  etag: string
  lastModified: string
}

/**
 * Structure du dépôt selon le millésime. Elle a changé DEUX fois, et c'est le
 * piège principal de l'acquisition :
 *
 *   2017-07-06 → 2018-01-02  aucun agrégat. Uniquement
 *                            geojson/communes/{dep}/{insee}/ — ~35 000 fichiers.
 *   2018-04-03 → 2022-04-01  shp/france/ et shp/departements/ apparaissent.
 *   2022-07-01 → aujourd'hui geojson/france/ et geojson/departements/ aussi.
 *
 * Conséquence : 32 des 35 millésimes se chargent avec UN seul fichier national.
 * Itérer par département — ou pire par commune — sur toute la profondeur, comme
 * le faisait l'ancienne version, ne sert que pour les 3 plus anciens.
 */
export type StrategieSource = 'geojson-france' | 'shp-france' | 'geojson-par-commune'

/** Premier millésime offrant un agrégat national, par format. */
const PREMIER_SHP_FRANCE = '2018-04-03'
const PREMIER_GEOJSON_FRANCE = '2022-07-01'

export function strategiePour(millesime: string): StrategieSource {
  if (millesime >= PREMIER_GEOJSON_FRANCE) return 'geojson-france'
  if (millesime >= PREMIER_SHP_FRANCE) return 'shp-france'
  return 'geojson-par-commune'
}

/** Les couches réellement disponibles au niveau national (les autres sont par département). */
const COUCHES_FRANCE: Couche[] = ['communes', 'sections', 'feuilles', 'prefixes_sections']

export function estDisponibleAuNiveauFrance(couche: Couche): boolean {
  return COUCHES_FRANCE.includes(couche)
}

interface ReponseListe {
  objets: ObjetS3[]
  prefixes: string[]
  suite?: string
}

/**
 * Un appel ListObjectsV2. Le XML est volontairement lu à la regex plutôt qu'avec
 * un parseur : la réponse S3 a un schéma fixe et trivial, et ça évite une
 * dépendance XML pour trois champs.
 */
async function listerUnePage(
  prefix: string,
  delimiter?: string,
  suite?: string,
): Promise<ReponseListe> {
  const params = new URLSearchParams({ 'list-type': '2', prefix, 'max-keys': '1000' })
  if (delimiter) params.set('delimiter', delimiter)
  if (suite) params.set('continuation-token', suite)

  const reponse = await fetch(`${BUCKET}/?${params}`)
  if (!reponse.ok) {
    throw new Error(`ListObjectsV2 a échoué (${reponse.status}) sur le préfixe ${prefix}`)
  }
  const xml = await reponse.text()

  const objets: ObjetS3[] = []
  for (const bloc of xml.matchAll(/<Contents>([\s\S]*?)<\/Contents>/g)) {
    const c = bloc[1]!
    const champ = (nom: string) => c.match(new RegExp(`<${nom}>([^<]*)</${nom}>`))?.[1] ?? ''
    objets.push({
      key: champ('Key'),
      size: Number(champ('Size')),
      etag: champ('ETag').replaceAll('"', ''),
      lastModified: champ('LastModified'),
    })
  }

  const prefixes = [...xml.matchAll(/<CommonPrefixes><Prefix>([^<]*)<\/Prefix><\/CommonPrefixes>/g)]
    .map((m) => m[1]!)

  const tronque = /<IsTruncated>true<\/IsTruncated>/.test(xml)
  const token = xml.match(/<NextContinuationToken>([^<]*)<\/NextContinuationToken>/)?.[1]

  return { objets, prefixes, suite: tronque ? token : undefined }
}

/** Liste toutes les clés sous un préfixe, en suivant la pagination. */
export async function listerObjets(prefix: string): Promise<ObjetS3[]> {
  const tout: ObjetS3[] = []
  let suite: string | undefined
  do {
    const page = await listerUnePage(prefix, undefined, suite)
    tout.push(...page.objets)
    suite = page.suite
  } while (suite)
  return tout
}

/** Les millésimes disponibles, du plus ancien au plus récent. */
export async function listerMillesimes(): Promise<string[]> {
  const { prefixes } = await listerUnePage(`${ROOT}/`, '/')
  return prefixes
    .map((p) => p.slice(`${ROOT}/`.length).replace(/\/$/, ''))
    .filter((m) => /^\d{4}-\d{2}-\d{2}$/.test(m))
    .sort()
}

export interface FichierSource {
  millesime: string
  couche: Couche
  strategie: StrategieSource
  /** Le département visé, ou null pour un agrégat national. */
  departement: string | null
  /** Format réel du fichier, qui décide de la façon de l'ouvrir avec GDAL. */
  format: 'geojson' | 'shp'
  url: string
  key: string
  size: number
  etag: string
  lastModified: string
  /** Nom du fichier dans le cache local. */
  nomLocal: string
}

/**
 * Le fichier national d'une couche pour un millésime, s'il existe.
 * Retourne null quand le millésime est antérieur aux agrégats (les 3 de 2017) :
 * l'appelant doit alors basculer sur le parcours par commune.
 */
export async function fichierNational(
  millesime: string,
  couche: Couche,
): Promise<FichierSource | null> {
  const strategie = strategiePour(millesime)
  if (strategie === 'geojson-par-commune') return null
  if (!estDisponibleAuNiveauFrance(couche)) return null

  const key =
    strategie === 'geojson-france'
      ? `${ROOT}/${millesime}/geojson/france/cadastre-france-${couche}.json.gz`
      : `${ROOT}/${millesime}/shp/france/cadastre-france-${couche}-shp.zip`

  const [objet] = await listerObjets(key)
  if (!objet || objet.key !== key) return null

  const format = strategie === 'geojson-france' ? 'geojson' : 'shp'
  return {
    millesime,
    couche,
    strategie,
    departement: null,
    format,
    key,
    url: `${BUCKET}/${key}`,
    size: objet.size,
    etag: objet.etag,
    lastModified: objet.lastModified,
    nomLocal:
      format === 'geojson'
        ? `cadastre-france-${couche}-${millesime}.json.gz`
        : `cadastre-france-${couche}-${millesime}-shp.zip`,
  }
}

/**
 * Le fichier d'une couche pour UN département.
 *
 * C'est la seule voie d'accès aux parcelles : contrairement aux communes et aux
 * sections, elles ne sont jamais agrégées au niveau national — le fichier ferait
 * plusieurs dizaines de Go. Le découpage départemental n'est donc pas un choix
 * de notre part, c'est la granularité de publication.
 *
 * Retourne null pour les 3 millésimes de 2017, antérieurs aux agrégats
 * départementaux (seul geojson/communes/{dep}/{insee}/ existe alors).
 */
export async function fichierDepartemental(
  millesime: string,
  departement: string,
  couche: Couche,
): Promise<FichierSource | null> {
  const strategie = strategiePour(millesime)
  if (strategie === 'geojson-par-commune') return null

  const format = strategie === 'geojson-france' ? 'geojson' : 'shp'
  const key =
    format === 'geojson'
      ? `${ROOT}/${millesime}/geojson/departements/${departement}/cadastre-${departement}-${couche}.json.gz`
      : `${ROOT}/${millesime}/shp/departements/${departement}/cadastre-${departement}-${couche}-shp.zip`

  const [objet] = await listerObjets(key)
  if (!objet || objet.key !== key) return null

  return {
    millesime,
    couche,
    strategie,
    departement,
    format,
    key,
    url: `${BUCKET}/${key}`,
    size: objet.size,
    etag: objet.etag,
    lastModified: objet.lastModified,
    nomLocal:
      format === 'geojson'
        ? `cadastre-${departement}-${couche}-${millesime}.json.gz`
        : `cadastre-${departement}-${couche}-${millesime}-shp.zip`,
  }
}
