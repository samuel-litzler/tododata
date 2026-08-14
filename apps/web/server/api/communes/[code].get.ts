/**
 * Fiche complète d'une commune : son identité officielle, sa présence
 * cadastrale millésime par millésime, ses mouvements INSEE, et le découpage
 * de son territoire en groupes de sections — dont ceux héritant d'anciennes
 * communes absorbées.
 */
export default defineEventHandler(async (event) => {
  const code = getRouterParam(event, 'code')
  if (!code || !/^[0-9AB]{5}$/i.test(code)) {
    throw createError({ statusCode: 400, statusMessage: 'Code INSEE invalide' })
  }
  const c = code.toUpperCase()

  const [identite] = await q(
    `
    SELECT $1::text AS code,
           (SELECT libelle FROM insee.commune_2026 WHERE com = $1 AND typecom = 'COM') AS nom_cog,
           (SELECT dep     FROM insee.commune_2026 WHERE com = $1 AND typecom = 'COM') AS departement,
           (SELECT nom FROM cad.observation WHERE code_insee = $1
             ORDER BY millesime DESC LIMIT 1)                                           AS nom_cadastre,
           -- un arrondissement municipal n'est pas une anomalie : le cadastre
           -- découpe Paris, Lyon et Marseille là où le COG ne voit qu'une commune
           (SELECT comparent FROM insee.commune_2026 WHERE com = $1 AND typecom = 'ARM') AS arm_parent
  `,
    [c],
  )

  const periodes = await q(
    `SELECT libelle, date_debut::text AS debut, date_fin::text AS fin
       FROM insee.commune_depuis_1943
      WHERE com = $1 AND typecom = 'COM' ORDER BY date_debut`,
    [c],
  )

  const presence = await q(
    `SELECT m.millesime::text,
            (p.code_insee IS NOT NULL)                       AS present,
            coalesce(p.origine, 'absente')                   AS origine,
            (SELECT nom FROM cad.observation o
              WHERE o.code_insee = $1 AND o.millesime = m.millesime) AS nom
       FROM cad.millesime m
       LEFT JOIN cad.presence p ON p.millesime = m.millesime AND p.code_insee = $1
      ORDER BY m.millesime`,
    [c],
  )

  const mouvements = await q(
    `SELECT mod, date_eff::text AS date, com_av, libelle_av, typecom_av,
            com_ap, libelle_ap, typecom_ap,
            CASE WHEN com_ap = $1 AND com_av <> $1 THEN 'entrant'
                 WHEN com_av = $1 AND com_ap <> $1 THEN 'sortant'
                 ELSE 'interne' END AS sens
       FROM insee.mvt_commune
      WHERE com_av = $1 OR com_ap = $1
      ORDER BY date_eff, mod, com_av`,
    [c],
  )

  // Le découpage territorial. ST_MakeValid est obligatoire : 13 % des géométries
  // de cette couche sont invalides à la source (anneaux à moins de 3 points,
  // auto-intersections). 'method=structure' exige GEOS >= 3.10.
  const territoires = await q(
    `
    WITH p AS (
      SELECT prefixe,
             nullif(ancienne,'')                                        AS ancienne,
             nullif(nom,'')                                             AS nom_cadastre,
             (CASE WHEN commune ~ '^97' THEN substr(commune,1,3)
                   ELSE substr(commune,1,2) END) || prefixe             AS code_reconstitue,
             ST_MakeValid(geom, 'method=structure')                      AS geom
      FROM raw.prefixes_sections_2026_06_01 WHERE commune = $1
    )
    SELECT p.prefixe,
           p.ancienne,
           i.libelle                                                    AS nom_insee,
           p.nom_cadastre,
           CASE WHEN p.prefixe = '000'    THEN 'noyau'
                WHEN i.libelle IS NOT NULL THEN 'absorbee'
                -- un préfixe qui n'est pas un code commune est une subdivision
                -- cadastrale interne (Marseille, Toulouse) : ce n'est pas une
                -- donnée manquante
                ELSE 'quartier' END                                     AS nature,
           CASE WHEN i.libelle IS NULL THEN NULL
                ELSE p.code_reconstitue END                             AS code,
           i.date_fin::text                                             AS fin_insee,
           (SELECT max(v.date_eff)::text FROM insee.mvt_commune v
             WHERE v.com_av = p.code_reconstitue AND v.com_ap = $1)      AS fusion_le,
           round((ST_Area(p.geom::geography)/1e6)::numeric, 2)           AS km2,
           ST_AsGeoJSON(ST_SimplifyPreserveTopology(p.geom, 0.0003), 5)::json AS geometrie
    FROM p
    LEFT JOIN LATERAL (
      SELECT libelle, date_fin FROM insee.commune_depuis_1943
       WHERE com = p.code_reconstitue AND typecom = 'COM'
       ORDER BY date_debut DESC LIMIT 1
    ) i ON true
    ORDER BY p.prefixe
  `,
    [c],
  )

  const anomalies = await q(
    `SELECT regle, niveau, millesime::text, detail FROM qa.anomalie
      WHERE code_insee = $1 ORDER BY regle`,
    [c],
  )

  if (!identite?.nom_cog && !identite?.nom_cadastre && presence.every((p) => !p.present)) {
    throw createError({ statusCode: 404, statusMessage: `Commune ${c} inconnue` })
  }

  return { identite, periodes, presence, mouvements, territoires, anomalies }
})
