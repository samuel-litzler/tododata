/**
 * La vie d'une parcelle, et sa parenté.
 *
 * Trois choses en une réponse, parce qu'elles ne se lisent qu'ensemble :
 *   - l'identité et les états successifs de la parcelle,
 *   - sa chronologie d'événements,
 *   - son graphe de filiation, remonté ET redescendu sur plusieurs générations.
 *
 * LE GRAPHE EST PARCOURU SANS TENIR COMPTE DU SENS DES LIENS, et c'est le point
 * de conception qui compte ici.
 *
 * Première version : deux récursions symétriques, l'une remontant les ascendants,
 * l'autre descendant les descendants. Elle manquait tout un pan du voisinage. Si
 * une parcelle A se divise et qu'un de ses morceaux reçoit AUSSI du terrain d'une
 * parcelle B, alors B fait partie de l'histoire de A — mais la récursion
 * descendante, une fois arrivée au morceau, ne remontait jamais vers B. Sur un
 * cas réel du département, une parcelle issue de quatre prédécesseurs n'en
 * montrait qu'un seul selon la fiche par laquelle on l'abordait.
 *
 * On explore donc le VOISINAGE, dans les deux sens à chaque saut, et on renvoie
 * le sous-graphe induit : tous les liens dont les deux extrémités ont été
 * atteintes. Le sens, lui, n'est pas perdu — il sert au client à disposer les
 * nœuds par génération.
 *
 * Deux bornes, parce qu'un remaniement cadastral peut relier des centaines de
 * parcelles voisines et que le graphe cesserait de raconter l'histoire d'un
 * terrain pour devenir une vue du quartier. Quand elles mordent, on le DIT :
 * `tronque` remonte au client, qui doit l'afficher plutôt que de laisser croire
 * à un voisinage complet.
 */
const SAUTS = 4
const MAX_NOEUDS = 60

interface Noeud {
  id: string
  commune: string
  prefixe: string
  section: string
  numero: string
  contenance: number | null
  surface_m2: number | null
  presente: boolean
  vu_premier: string
  vu_dernier: string
  geom: unknown
}

interface Lien {
  id_avant: string
  id_apres: string
  type: string
  part_avant: number | null
  part_apres: number | null
  certain: boolean
  millesime: string
  saut: number
}

export default defineEventHandler(async (event) => {
  const id = getRouterParam(event, 'id')?.toUpperCase()
  // 14 caractères : commune(5) + préfixe(3) + section(2) + numéro(4).
  // L'alphabet est large : la section peut porter n'importe quelles lettres
  // (« CL », « ZB », « 0A »…). Ne pas confondre avec le motif d'un code commune,
  // qui lui se limite aux chiffres et aux A/B corses.
  if (!id || !/^[0-9A-Z]{14}$/.test(id)) {
    throw createError({ statusCode: 400, statusMessage: 'Identifiant de parcelle invalide' })
  }

  const [parcelle] = await q<{
    id_parcelle: string
    commune: string
    prefixe: string
    section: string
    numero: string
    n_versions: number
    vu_premier: string
    vu_dernier: string
    presente: boolean
    apparition_observee: boolean
    cree_source: string | null
    maj_source: string | null
    anterieure_a_nos_releves: boolean
  }>(
    `SELECT id_parcelle, commune, prefixe, section, numero, n_versions,
            to_char(vu_premier,'YYYY-MM-DD') AS vu_premier,
            to_char(vu_dernier,'YYYY-MM-DD') AS vu_dernier,
            presente, apparition_observee,
            to_char(cree_source,'YYYY-MM-DD') AS cree_source,
            to_char(maj_source,'YYYY-MM-DD')  AS maj_source,
            anterieure_a_nos_releves
       FROM parc.parcelle WHERE id_parcelle = $1`,
    [id],
  )

  if (!parcelle) {
    throw createError({ statusCode: 404, statusMessage: 'Parcelle inconnue' })
  }

  const versions = await q(
    `SELECT no_version, contenance, arpente, surface_m2,
            to_char(vu_debut,'YYYY-MM-DD') AS vu_debut,
            to_char(vu_fin,'YYYY-MM-DD')   AS vu_fin
       FROM parc.version WHERE id_parcelle = $1 ORDER BY no_version`,
    [id],
  )

  const evenements = await q(
    `SELECT to_char(millesime,'YYYY-MM-DD') AS millesime, type, detail, no_version
       FROM parc.evenement WHERE id_parcelle = $1 ORDER BY millesime, type`,
    [id],
  )

  // --- Le graphe ----------------------------------------------------------
  // Parcours non orienté du voisinage. Le garde-fou sur `saut` est
  // indispensable : rien dans le schéma n'interdit formellement un cycle, et une
  // récursion non bornée sur une table de filiation est une boucle infinie qui
  // ne se signale que par la saturation du serveur.
  const [portee] = await q<{ atteints: number; retenus: number }>(
    `
    WITH RECURSIVE reach AS (
      SELECT $1::text AS id, 0 AS saut
      UNION
      SELECT CASE WHEN f.id_avant = r.id THEN f.id_apres ELSE f.id_avant END,
             r.saut + 1
        FROM reach r
        JOIN parc.filiation f ON f.id_avant = r.id OR f.id_apres = r.id
       WHERE r.saut < $2
    )
    SELECT count(DISTINCT id)::int AS atteints,
           least(count(DISTINCT id), $3)::int AS retenus
      FROM reach
  `,
    [id, SAUTS, MAX_NOEUDS],
  )

  const liens = await q<Lien>(
    `
    WITH RECURSIVE reach AS (
      SELECT $1::text AS id, 0 AS saut
      UNION
      SELECT CASE WHEN f.id_avant = r.id THEN f.id_apres ELSE f.id_avant END,
             r.saut + 1
        FROM reach r
        JOIN parc.filiation f ON f.id_avant = r.id OR f.id_apres = r.id
       WHERE r.saut < $2
    ),
    -- Les plus proches d'abord : si la borne mord, on ampute la périphérie, pas
    -- le voisinage immédiat.
    proche AS (
      SELECT id, min(saut) AS saut FROM reach GROUP BY id
      ORDER BY min(saut), id LIMIT $3
    )
    SELECT f.id_avant, f.id_apres, f.type, f.part_avant, f.part_apres, f.certain,
           to_char(f.millesime,'YYYY-MM-DD') AS millesime,
           least(a.saut, b.saut) AS saut
      FROM parc.filiation f
      JOIN proche a ON a.id = f.id_avant
      JOIN proche b ON b.id = f.id_apres
     ORDER BY saut, f.id_avant, f.id_apres
  `,
    [id, SAUTS, MAX_NOEUDS],
  )

  // Les entités du graphe : la parcelle elle-même plus tout ce que les liens
  // touchent. On charge leur dernière géométrie connue pour pouvoir situer le
  // graphe sur une carte — un arbre de filiation sans le terrain qu'il décrit
  // reste abstrait.
  const ids = [...new Set([id, ...liens.flatMap((l) => [l.id_avant, l.id_apres])])]

  const noeuds = await q<Noeud>(
    `
    SELECT p.id_parcelle AS id, p.commune, p.prefixe, p.section, p.numero,
           v.contenance, v.surface_m2, p.presente,
           to_char(p.vu_premier,'YYYY-MM-DD') AS vu_premier,
           to_char(p.vu_dernier,'YYYY-MM-DD') AS vu_dernier,
           ST_AsGeoJSON(ST_SimplifyPreserveTopology(v.geom, 0.0000025), 6)::json AS geom
      FROM parc.parcelle p
      -- La version la plus récente : c'est le dernier état connu de la parcelle,
      -- celui qu'il faut montrer pour situer le terrain.
      JOIN LATERAL (
        SELECT geom, contenance, surface_m2 FROM parc.version v2
         WHERE v2.id_parcelle = p.id_parcelle
         ORDER BY v2.no_version DESC LIMIT 1
      ) v ON true
     WHERE p.id_parcelle = ANY($1)
  `,
    [ids],
  )

  // Le nom tel que le cadastre l'a vu au relevé le plus récent où la commune
  // existait encore. Suffisant ici : la fiche commune, elle, confronte ce nom au
  // COG et expose les écarts.
  const [commune] = await q<{ nom: string }>(
    `SELECT nom FROM cad.observation
      WHERE code_insee = $1 ORDER BY millesime DESC LIMIT 1`,
    [parcelle.commune],
  )

  // Le préfixe non-'000' porte le code INSEE de la commune absorbée dont la
  // parcelle dépendait. C'est une déduction, et la fiche doit le dire.
  const [absorbee] = parcelle.prefixe === '000'
    ? []
    : await q<{ com: string; libelle: string; date_fin: string | null }>(
        `SELECT com, libelle, to_char(date_fin,'YYYY-MM-DD') AS date_fin
           FROM insee.commune_depuis_1943
          WHERE com = $1 ORDER BY date_debut DESC LIMIT 1`,
        [parcelle.commune.slice(0, 2) + parcelle.prefixe],
      )

  // Nom de TOUTES les communes présentes dans le graphe, pas seulement celle de
  // la parcelle consultée : une filiation peut traverser une frontière communale,
  // et c'est justement le cas le plus intéressant à donner à lire.
  const codesCommunes = [...new Set(noeuds.map((n) => n.commune))]
  const nomsCommunes = await q<{ code: string; nom: string }>(
    `SELECT DISTINCT ON (code_insee) code_insee AS code, nom
       FROM cad.observation WHERE code_insee = ANY($1)
      ORDER BY code_insee, millesime DESC`,
    [codesCommunes],
  )

  // --- Les mutations ------------------------------------------------------
  // dvf.vente et non dvf.mutation_parcelle : c'est le grain stable. L'identifiant
  // de mutation étant dérivé du contenu, toute recomposition en ouvre un nouveau
  // — 11,3 % des ventes en ont porté deux — et la fiche verrait des ventes
  // disparaître puis revenir sans que rien n'ait bougé.
  //
  // `avec_lots` est remonté tel quel parce qu'il change le SENS de la vente :
  // quand un appartement se vend, la parcelle appartient à la copropriété et ne
  // change pas de main. Mesuré en croisant avec le fichier des personnes morales,
  // un changement de propriétaire accompagne 83 % des ventes hors lots contre
  // 18,6 % des ventes de lots. La page doit pouvoir le dire.
  // Les `numeric` et les `bigint` sont rendus en CHAÎNES par le pilote — c'est
  // le seul moyen de ne pas perdre de précision sur des types que JavaScript ne
  // sait pas représenter. Ici les montants tiennent tous dans un double, et le
  // type de retour annonce `number` : on convertit à la frontière plutôt que de
  // laisser une chaîne se promener. Sans cette conversion, la médiane d'un
  // nombre pair de prix concatène au lieu d'additionner et rend NaN.
  const ventes = await q(
    `SELECT to_char(date_mutation,'YYYY-MM-DD') AS date_mutation,
            nature, avec_lots, types,
            valeur::float8          AS valeur,
            surface_bati::float8    AS surface_bati,
            surface_terrain::float8 AS surface_terrain,
            n_prix::int             AS n_prix,
            retard_jours,
            to_char(vu_debut,'YYYY-MM-DD') AS vu_debut
       FROM dvf.vente WHERE id_parcelle = $1 ORDER BY date_mutation`,
    [id],
  )

  // Les ventes des parcelles dont celle-ci hérite du sol. Une parcelle née d'une
  // division n'a jamais été vendue elle-même, mais son terrain l'a été sous un
  // autre numéro — et c'est souvent le seul prix qu'on puisse lui rattacher.
  //
  // Une seule génération, volontairement : chaque saut supplémentaire dilue le
  // lien. `part` dit ce qu'on a hérité, pour qu'un prix venu d'un prédécesseur
  // dont on ne tient que 4 % ne se lise pas comme un prix de la parcelle.
  const ventesHeritees = ventes.length
    ? []
    : await q(
        `SELECT to_char(v.date_mutation,'YYYY-MM-DD') AS date_mutation,
                v.nature, v.avec_lots, v.types,
                v.valeur::float8          AS valeur,
                v.surface_terrain::float8 AS surface_terrain,
                f.id_avant AS herite_de, f.type AS filiation, f.part_apres AS part
           FROM parc.filiation f
           JOIN dvf.vente v ON v.id_parcelle = f.id_avant
          WHERE f.id_apres = $1
          ORDER BY v.date_mutation DESC LIMIT 12`,
        [id],
      )

  setHeader(event, 'Cache-Control', 'public, max-age=300')

  return {
    parcelle,
    versions,
    evenements,
    ventes,
    ventesHeritees,
    liens,
    noeuds,
    commune: commune?.nom ?? null,
    absorbee: absorbee ?? null,
    communes: Object.fromEntries(nomsCommunes.map((c) => [c.code, c.nom])),
    // Le voisinage a-t-il été amputé par les bornes ? La page doit le dire.
    tronque: (portee?.atteints ?? 0) > MAX_NOEUDS,
    atteints: portee?.atteints ?? 0,
  }
})
