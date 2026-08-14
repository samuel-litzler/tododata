/**
 * Tuiles vectorielles générées à la volée par PostGIS.
 *
 * Deux couches dans la même tuile, choisies selon le zoom :
 *   z < 8   → uniquement les départements (silhouettes)
 *   z = 8   → départements + communes en silhouette
 *   z >= 9  → communes au détail cadastral
 *
 * Le seuil des communes est à 8 et non 7 : une tuile de z7 couvre trop de
 * communes pour rester légère, et les départements suffisent à s'orienter.
 *
 * Mettre les deux couches dans une seule tuile évite de doubler les requêtes
 * HTTP, et MapLibre sait n'afficher que celle qui l'intéresse à chaque niveau.
 */
export default defineEventHandler(async (event) => {
  const z = Number(getRouterParam(event, 'z'))
  const x = Number(getRouterParam(event, 'x'))
  const y = Number(getRouterParam(event, 'y'))

  // Garde-fou : sans validation, un z absurde ferait calculer une enveloppe
  // dégénérée et scanner toute la table.
  if (![z, x, y].every(Number.isInteger) || z < 0 || z > 18) {
    throw createError({ statusCode: 400, statusMessage: 'Coordonnées de tuile invalides' })
  }
  const max = 2 ** z
  if (x < 0 || x >= max || y < 0 || y >= max) {
    throw createError({ statusCode: 400, statusMessage: 'Tuile hors de la pyramide' })
  }

  const avecDepartements = z < 9
  const avecCommunes = z >= 8
  // La colonne pré-simplifiée en dessous de z 9 : à cette échelle le détail
  // cadastral représente des millions de points invisibles.
  // Géométrie d'AFFICHAGE et non géographique : les DROM y sont rapprochés de
  // la métropole en cartouches. Les mesures, elles, restent sur `geom`.
  // Trois paliers de détail. Au-delà de z12 la simplification devient visible à
  // l'écran, on sert donc la géométrie non simplifiée : ST_AsMVTGeom découpe déjà
  // par tuile, le surcoût est marginal à ces échelles.
  const colonne = z >= 12 ? 'geom_carte_full' : z >= 9 ? 'geom_carte' : 'geom_carte_low'
  // Idem pour les contours : le trait fin ne sert qu'à partir de z8.
  const colonneLigne = z >= 12 ? 'ligne_carte_full' : z >= 8 ? 'ligne_carte' : 'ligne_carte_low'
  const colonneDep = z >= 7 ? 'geom_carte' : 'geom_carte_low'

  const rows = await q<{ tuile: Buffer | null }>(
    `
    WITH env AS (SELECT ST_TileEnvelope($1, $2, $3) AS e),
    dep AS (
      SELECT ST_AsMVT(d, 'departements', 4096, 'geom') AS mvt
      FROM (
        SELECT code, nom, region, nb_communes, nb_absorbees,
               ST_AsMVTGeom(d.${colonneDep}, env.e, 4096, 16, true) AS geom
        FROM carte.departement d, env
        WHERE $4 AND d.${colonneDep} && env.e
      ) d
    ),
    com AS (
      SELECT ST_AsMVT(c, 'communes', 4096, 'geom') AS mvt
      FROM (
        SELECT code_insee, nom, departement, nb_absorbees, km2,
               ST_AsMVTGeom(c.${colonne}, env.e, 4096, 16, true) AS geom
        FROM carte.commune c, env
        WHERE $5 AND c.${colonne} && env.e
      ) c
    ),
    -- Les limites sont servies à TOUS les zooms : sans elles on perd tout repère
    -- dès qu'on descend sur les communes. Elles viennent de colonnes de LIGNES
    -- pré-calculées, car découper un contour départemental à chaque tuile de z12
    -- coûterait bien plus cher que de découper son polygone, pour le même trait.
    dep_lignes AS (
      SELECT ST_AsMVT(d, 'limites_departements', 4096, 'geom') AS mvt
      FROM (
        SELECT code, nom, ST_AsMVTGeom(d.${colonneLigne}, env.e, 4096, 16, true) AS geom
        FROM carte.departement d, env
        WHERE d.${colonneLigne} && env.e
      ) d
    ),
    reg AS (
      SELECT ST_AsMVT(r, 'limites_regions', 4096, 'geom') AS mvt
      FROM (
        SELECT code, nom, ST_AsMVTGeom(r.${colonneLigne}, env.e, 4096, 16, true) AS geom
        FROM carte.region r, env
        WHERE r.${colonneLigne} && env.e
      ) r
    )
    -- coalesce sur chaque morceau : une couche sans entité renvoie NULL, et un
    -- seul NULL dans la concaténation annulerait la tuile entière.
    SELECT coalesce((SELECT mvt FROM dep), ''::bytea)
        || coalesce((SELECT mvt FROM com), ''::bytea)
        || coalesce((SELECT mvt FROM dep_lignes), ''::bytea)
        || coalesce((SELECT mvt FROM reg), ''::bytea) AS tuile
  `,
    [z, x, y, avecDepartements, avecCommunes],
  )

  const tuile = rows[0]?.tuile
  setHeader(event, 'Content-Type', 'application/vnd.mapbox-vector-tile')
  // Les tuiles ne changent qu'à l'ingestion de nouvelles données : un cache
  // long est sans risque et évite de recalculer les mêmes tuiles en boucle.
  setHeader(event, 'Cache-Control', 'public, max-age=86400')

  if (!tuile || tuile.length === 0) {
    // 204 plutôt que 404 : une tuile vide est un cas normal (mer, étranger),
    // et MapLibre arrête de la redemander.
    setResponseStatus(event, 204)
    return null
  }

  // Content-Length explicite : sans lui h3 peut basculer en chunked, et certains
  // clients de tuiles n'aiment pas ça.
  setHeader(event, 'Content-Length', tuile.length)
  return tuile
})
