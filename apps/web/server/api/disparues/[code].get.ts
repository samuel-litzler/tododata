/**
 * Fiche d'une commune qui n'existe plus.
 *
 * Son identité vient du registre historique de l'INSEE, mais sa GÉOMÉTRIE n'est
 * disponible dans aucune source contemporaine : elle survit uniquement dans le
 * découpage en sections de la commune qui l'a absorbée, sous un préfixe égal à
 * son ancien numéro. C'est le seul moyen de la dessiner aujourd'hui.
 */
export default defineEventHandler(async (event) => {
  const code = getRouterParam(event, 'code')
  if (!code || !/^[0-9AB]{5}$/i.test(code)) {
    throw createError({ statusCode: 400, statusMessage: 'Code INSEE invalide' })
  }
  const c = code.toUpperCase()

  const periodes = await q<{ libelle: string; debut: string; fin: string | null }>(
    `SELECT libelle, date_debut::text AS debut, date_fin::text AS fin
       FROM insee.commune_depuis_1943
      WHERE com = $1 AND typecom = 'COM' ORDER BY date_debut`,
    [c],
  )
  if (!periodes.length) {
    throw createError({ statusCode: 404, statusMessage: `Aucune commune ${c} au registre INSEE` })
  }

  // Toujours vivante ? Alors ce n'est pas une commune disparue.
  const [vivante] = await q(`SELECT code_insee FROM carte.commune WHERE code_insee = $1`, [c])

  // Le territoire, retrouvé via le préfixe de section chez l'absorbante.
  const [territoire] = await q(
    `
    SELECT p.commune                                   AS absorbante_code,
           cc.nom                                      AS absorbante_nom,
           cc.departement,
           p.prefixe,
           round((ST_Area(g.geom::geography)/1e6)::numeric, 2) AS km2,
           ST_AsGeoJSON(ST_SimplifyPreserveTopology(g.geom, 0.0002), 5)::json AS geometrie,
           ST_XMin(b) AS xmin, ST_YMin(b) AS ymin, ST_XMax(b) AS xmax, ST_YMax(b) AS ymax
      FROM raw.prefixes_sections_2026_06_01 p
      CROSS JOIN LATERAL (SELECT ST_MakeValid(p.geom, 'method=structure') AS geom) g
      CROSS JOIN LATERAL (SELECT ST_Envelope(g.geom) AS b) e
      LEFT JOIN carte.commune cc ON cc.code_insee = p.commune
     WHERE p.prefixe <> '000'
       AND (CASE WHEN p.commune ~ '^97' THEN substr(p.commune,1,3)
                 ELSE substr(p.commune,1,2) END) || p.prefixe = $1
     LIMIT 1`,
    [c],
  )

  // Le contour de l'absorbante, pour situer le territoire dans son ensemble.
  const [contexte] = territoire
    ? await q(
        `SELECT ST_AsGeoJSON(ST_Transform(ST_SimplifyPreserveTopology(geom, 30), 4326), 5)::json AS geometrie
           FROM carte.commune WHERE code_insee = $1`,
        [territoire.absorbante_code],
      )
    : [null]

  const mouvements = await q(
    `SELECT mod, date_eff::text AS date, com_av, libelle_av, com_ap, libelle_ap,
            CASE WHEN com_av = $1 AND com_ap <> $1 THEN 'sortant' ELSE 'entrant' END AS sens
       FROM insee.mvt_commune
      WHERE (com_av = $1 OR com_ap = $1) AND com_av <> com_ap
      ORDER BY date_eff, mod`,
    [c],
  )

  // Les autres communes disparues dans la même absorbante : elles racontent
  // ensemble une même opération de fusion.
  const soeurs = territoire
    ? await q(
        `
      WITH p AS (
        SELECT prefixe,
               (CASE WHEN commune ~ '^97' THEN substr(commune,1,3)
                     ELSE substr(commune,1,2) END) || prefixe AS code
        FROM raw.prefixes_sections_2026_06_01
        WHERE commune = $1 AND prefixe <> '000'
      )
      SELECT p.code, i.libelle AS nom, i.date_fin::text AS fin
        FROM p JOIN LATERAL (
          SELECT libelle, date_fin FROM insee.commune_depuis_1943
           WHERE com = p.code AND typecom = 'COM' ORDER BY date_debut DESC LIMIT 1
        ) i ON true
       WHERE p.code <> $2
       ORDER BY i.libelle`,
        [territoire.absorbante_code, c],
      )
    : []

  return {
    code: c,
    nom: periodes.at(-1)!.libelle,
    encore_vivante: !!vivante,
    periodes,
    territoire: territoire ?? null,
    contexte_geometrie: contexte?.geometrie ?? null,
    mouvements,
    soeurs,
  }
})
