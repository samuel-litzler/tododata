/**
 * Résumé léger d'une commune, pour le volet latéral de la carte.
 *
 * Volontairement SANS géométrie : le volet s'ouvre au clic et doit apparaître
 * instantanément, alors que la fiche complète transporte des polygones. La carte
 * a déjà la géométrie, inutile de la lui renvoyer.
 */
export default defineEventHandler(async (event) => {
  const code = getRouterParam(event, 'code')
  if (!code || !/^[0-9AB]{5}$/i.test(code)) {
    throw createError({ statusCode: 400, statusMessage: 'Code INSEE invalide' })
  }
  const c = code.toUpperCase()

  const [identite] = await q(
    `SELECT c.code_insee AS code, c.nom, c.departement, c.km2, c.nb_absorbees,
            (SELECT count(*)::int FROM cad.presence p WHERE p.code_insee = c.code_insee) AS millesimes_vus,
            (SELECT count(*)::int FROM cad.presence p
              WHERE p.code_insee = c.code_insee AND p.origine = 'comblee')                AS millesimes_combles,
            (SELECT count(*)::int FROM cad.millesime)                                     AS millesimes_total
       FROM carte.commune c WHERE c.code_insee = $1`,
    [c],
  )
  if (!identite) throw createError({ statusCode: 404, statusMessage: `Commune ${c} inconnue` })

  const periodes = await q(
    `SELECT libelle, date_debut::text AS debut, date_fin::text AS fin
       FROM insee.commune_depuis_1943
      WHERE com = $1 AND typecom = 'COM' ORDER BY date_debut`,
    [c],
  )

  // Les communes absorbées, telles que le cadastre les garde en mémoire via le
  // préfixe de section — y compris celles disparues avant tout registre numérique.
  const absorbees = await q(
    `
    WITH p AS (
      SELECT prefixe,
             (CASE WHEN commune ~ '^97' THEN substr(commune,1,3)
                   ELSE substr(commune,1,2) END) || prefixe AS code,
             nullif(ancienne,'') AS ancienne,
             round((ST_Area(ST_MakeValid(geom,'method=structure')::geography)/1e6)::numeric,2) AS km2
      FROM raw.prefixes_sections_2026_06_01 WHERE commune = $1 AND prefixe <> '000'
    )
    SELECT p.code, p.prefixe, p.ancienne, p.km2, i.libelle AS nom, i.date_fin::text AS fin,
           (SELECT max(v.date_eff)::text FROM insee.mvt_commune v
             WHERE v.com_av = p.code AND v.com_ap = $1) AS fusion_le
    FROM p
    JOIN LATERAL (
      SELECT libelle, date_fin FROM insee.commune_depuis_1943
       WHERE com = p.code AND typecom = 'COM' ORDER BY date_debut DESC LIMIT 1
    ) i ON true
    ORDER BY coalesce(p.km2, 0) DESC
  `,
    [c],
  )

  const mouvements = await q(
    `SELECT mod, date_eff::text AS date, com_av, libelle_av, com_ap, libelle_ap,
            CASE WHEN com_ap = $1 AND com_av <> $1 THEN 'entrant' ELSE 'sortant' END AS sens
       FROM insee.mvt_commune
      WHERE (com_av = $1 OR com_ap = $1) AND com_av <> com_ap
      ORDER BY date_eff DESC, mod LIMIT 30`,
    [c],
  )

  const presence = await q(
    `SELECT m.millesime::text, (p.code_insee IS NOT NULL) AS present,
            coalesce(p.origine,'absente') AS origine
       FROM cad.millesime m
       LEFT JOIN cad.presence p ON p.millesime = m.millesime AND p.code_insee = $1
      ORDER BY m.millesime`,
    [c],
  )

  return { identite, periodes, absorbees, mouvements, presence }
})
