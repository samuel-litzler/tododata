/**
 * Ingestion des parcelles d'un département, sur toute la profondeur disponible.
 *
 * Le run est repris-able : chaque millésime distillé est journalisé dans
 * parc.millesime, et un millésime déjà présent est sauté. Couper le process et
 * le relancer reprend au relevé suivant.
 *
 * Le chargement passe par ogr2ogr plutôt que par un parseur GeoJSON en Node :
 * 1,5 M de polygones, c'est le terrain de GDAL, et son mode COPY écrit dans
 * Postgres bien plus vite que tout ce qu'on écrirait ici.
 */
import { execFile } from 'node:child_process'
import { mkdir, rename, stat, unlink } from 'node:fs/promises'
import { createWriteStream } from 'node:fs'
import { pipeline as flux } from 'node:stream/promises'
import { Readable } from 'node:stream'
import { join } from 'node:path'
import { promisify } from 'node:util'
import {
  listerMillesimes,
  fichierDepartemental,
  type FichierSource,
} from '../../../_shared/acquisition/cadastreCatalog.js'
import { pool } from '../../../_shared/db/pgClient.js'
import { logger } from '../../../_shared/observability/logger.js'
import { env } from '../../../env.js'

const executer = promisify(execFile)

const CACHE = join(env.dataDir, 'parcelles')
const mo = (n: number) => (n / 1024 ** 2).toFixed(0)

/** Télécharge le fichier s'il n'est pas déjà dans le cache local. */
async function recuperer(f: FichierSource): Promise<string> {
  await mkdir(CACHE, { recursive: true })
  const chemin = join(CACHE, f.nomLocal)

  const dejaLa = await stat(chemin).then((s) => s.size > 0).catch(() => false)
  if (dejaLa) return chemin

  logger.info(`  téléchargement ${f.nomLocal} (${mo(f.size)} Mo)`)
  const reponse = await fetch(f.url)
  if (!reponse.ok || !reponse.body) {
    throw new Error(`téléchargement impossible (${reponse.status}) : ${f.url}`)
  }
  // Écriture sous .part puis rename : un run interrompu ne laisse jamais un
  // fichier tronqué que le run suivant prendrait pour un téléchargement complet.
  const partiel = `${chemin}.part`
  await flux(Readable.fromWeb(reponse.body as never), createWriteStream(partiel))
  await rename(partiel, chemin)
  return chemin
}

/**
 * Charge un fichier source dans raw.parcelles_stage.
 *
 * Trois réglages non négociables :
 *
 *   -t_srs EPSG:4326    et surtout PAS -a_srs. Les shapefiles DÉPARTEMENTAUX
 *                       sont publiés en Lambert-93 (EPSG:2154), là où l'agrégat
 *                       national des communes, lui, est en WGS84 — d'où le
 *                       -a_srs du script communes, qui serait ici catastrophique :
 *                       il rebaptiserait des mètres en degrés sans rien convertir.
 *                       -t_srs reprojette, et ne fait rien si la source est déjà
 *                       dans le bon système.
 *   -nlt MULTIPOLYGON   le shapefile livre du MULTIPOLYGON, le GeoJSON du
 *                       POLYGON. Sans uniformisation, l'empreinte de contenu
 *                       change à la bascule de format et toutes les parcelles
 *                       passeraient pour modifiées en juillet 2022.
 *   SHAPE_ENCODING      laissé vide, GDAL renvoie des octets LATIN1 bruts dans
 *                       une base UTF-8. Ce piège a déjà coûté les millésimes
 *                       2018-2019 du pipeline communes.
 */
async function charger(f: FichierSource, chemin: string, table: string): Promise<void> {
  const source = f.format === 'geojson' ? `/vsigzip/${chemin}` : `/vsizip/${chemin}`
  const { host, port, user, password, database } = env.pg

  await pool.query(`TRUNCATE ${table}`)

  const { stderr } = await executer(
    'ogr2ogr',
    [
      '-f', 'PostgreSQL',
      `PG:host=${host} port=${port} dbname=${database} user=${user} password=${password}`,
      source,
      '-nln', table,
      '-append',
      '-nlt', 'MULTIPOLYGON',
      '-t_srs', 'EPSG:4326',
      '--config', 'PG_USE_COPY', 'YES',
      '--config', 'SHAPE_ENCODING', 'ISO-8859-1',
    ],
    { maxBuffer: 16 * 1024 * 1024, env: { ...process.env } },
  )
  if (stderr.trim()) logger.warn(`  ogr2ogr : ${stderr.trim().split('\n').slice(-3).join(' | ')}`)
}

interface Options {
  /**
   * Supprimer le fichier source une fois le relevé distillé.
   *
   * Indispensable pour un run national : 6,5 Go de sources pour la seule Moselle,
   * soit ~420 Go pour la France — plus que le disque n'en a à côté de la base.
   * L'empreinte du fichier étant en base, un retéléchargement reste possible.
   */
  purger?: boolean
}

export async function ingererParcelles(
  departement: string,
  options: Options = {},
): Promise<void> {
  // Schéma de travail propre au département : c'est lui qui rend deux ingestions
  // concurrentes inoffensives l'une pour l'autre.
  const schema = `travail_${departement.toLowerCase()}`
  const stage = `${schema}.parcelles_stage`
  await pool.query(`
    CREATE SCHEMA IF NOT EXISTS ${schema};
    DROP TABLE IF EXISTS ${stage};
    CREATE TABLE ${stage} (LIKE raw.parcelles_stage INCLUDING ALL);
  `)

  const { rows: deja } = await pool.query<{
    millesime: string
    etag: string | null
    taille: string | null
  }>(
    `SELECT to_char(millesime, 'YYYY-MM-DD') AS millesime, etag, taille
       FROM parc.millesime WHERE departement = $1`,
    [departement],
  )
  const traites = new Map(deja.map((r) => [r.millesime, r]))
  if (traites.size) {
    logger.info(`${departement} : ${traites.size} relevé(s) déjà distillé(s), reprise`)
  }
  const republies: string[] = []

  const millesimes = await listerMillesimes()
  let n = 0

  for (const millesime of millesimes) {
    const f = await fichierDepartemental(millesime, departement, 'parcelles')

    // Relevé déjà distillé : on ne le rejoue pas, mais on vérifie qu'il n'a pas
    // bougé à la source.
    //
    // L'idempotence par la seule date du relevé est un piège : l'archive Etalab
    // est RÉÉCRITE — au 15 août 2026, les fichiers de 2018 portaient une date de
    // publication de mars 2026. Un millésime ancien republié avec des données
    // corrigées serait donc sauté en silence. On ne peut pas le réingérer à la
    // volée (le modèle est chronologique, corriger 2020 impose de rejouer tout
    // l'aval), mais on peut refuser de l'ignorer.
    const connu = traites.get(millesime)
    if (connu) {
      // Rattrapage des relevés distillés avant que l'empreinte ne soit stockée.
      // On ne l'inscrit que si le fichier du cache local a EXACTEMENT la taille
      // annoncée par S3 : c'est la preuve qu'il n'a pas bougé depuis qu'on l'a
      // téléchargé, donc que l'empreinte actuelle est bien celle qu'on a
      // distillée. Sans cette garde, on figerait une empreinte postérieure à la
      // distillation et on rendrait la détection aveugle pour toujours.
      if (f && !connu.etag) {
        const local = await stat(join(CACHE, f.nomLocal))
          .then((st) => st.size)
          .catch(() => -1)
        if (local === f.size) {
          await pool.query(
            `UPDATE parc.millesime SET etag = $3, taille = $4, publie_le = $5::timestamptz
              WHERE departement = $1 AND millesime = $2::date`,
            [departement, millesime, f.etag, f.size, f.lastModified],
          )
        } else {
          logger.warn(
            `${millesime} : empreinte non rattrapée, le fichier local (${local} o) ` +
              `diffère de la source (${f.size} o).`,
          )
        }
      }
      if (f && connu.etag && connu.etag !== f.etag) {
        republies.push(millesime)
        logger.warn(
          `${millesime} : le fichier source a changé depuis la distillation ` +
            `(${connu.taille} → ${f.size} octets). Relevé NON rejoué.`,
        )
      }
      continue
    }

    if (!f) {
      // Les 3 relevés de 2017 n'existent qu'en par-commune : ~500 fichiers pour
      // ce seul département. Hors périmètre tant que le reste n'est pas validé.
      logger.warn(`${millesime} : pas d'agrégat départemental, ignoré`)
      continue
    }

    logger.info(`${millesime} (${f.format}, ${mo(f.size)} Mo)`)
    const debut = Date.now()
    const chemin = await recuperer(f)
    await charger(f, chemin, stage)

    const { rows } = await pool.query<{
      n_parcelles: number
      n_ouvertures: number
      n_fermetures: number
      n_disparitions: number
    }>(
      'SELECT * FROM parc.distiller($1, $2::date, $3, $4, $5, $6::timestamptz, $7)',
      [departement, millesime, f.format, f.etag, f.size, f.lastModified, schema],
    )

    const r = rows[0]!
    logger.info(
      `  ${r.n_parcelles.toLocaleString('fr-FR')} parcelles · ` +
        `+${r.n_ouvertures.toLocaleString('fr-FR')} versions · ` +
        `${r.n_fermetures.toLocaleString('fr-FR')} modifiées · ` +
        `${r.n_disparitions.toLocaleString('fr-FR')} disparues · ` +
        `${((Date.now() - debut) / 1000).toFixed(0)} s`,
    )
    n++

    // Purge après distillation RÉUSSIE seulement : si la distillation lève, le
    // fichier reste et le run suivant repart de lui sans retélécharger.
    if (options.purger) await unlink(chemin).catch(() => {})
  }

  // Le schéma de travail est jetable : le garder ferait traîner une table de
  // 1,5 M de lignes par département traité.
  await pool.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`)
  logger.info(`${departement} : ${n} relevé(s) distillé(s)`)

  if (republies.length) {
    logger.warn(
      `${republies.length} relevé(s) republié(s) à la source depuis leur distillation : ` +
        `${republies.join(', ')}. Les rejouer impose de repartir du plus ancien d'entre eux ` +
        `(TRUNCATE parc.version puis réingestion complète du département).`,
    )
  }
}
