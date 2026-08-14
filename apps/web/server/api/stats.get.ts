/**
 * Chiffres de tête : ce que le dernier passage d'ingestion a produit.
 * Requête unique, tout en agrégats — c'est la page d'accueil, elle doit être
 * instantanée.
 */
export default defineEventHandler(async () => {
  const [socle] = await q<{
    millesimes: number
    observations: string
    codes: number
    du: string
    au: string
  }>(`
    SELECT count(DISTINCT millesime)::int AS millesimes,
           count(*)                       AS observations,
           count(DISTINCT code_insee)::int AS codes,
           min(millesime)::text            AS du,
           max(millesime)::text            AS au
    FROM cad.observation
  `)

  const evenements = await q<{ evenement: string; n: number }>(`
    SELECT evenement_fin AS evenement, count(*)::int AS n
    FROM cad.evenement_presence WHERE evenement_fin IS NOT NULL GROUP BY 1
    UNION ALL
    SELECT evenement_debut, count(*)::int
    FROM cad.evenement_presence WHERE evenement_debut IS NOT NULL GROUP BY 1
    ORDER BY 2 DESC
  `)

  // Le décalage entre la date d'effet légale et la dernière observation
  // cadastrale : la mesure la plus parlante de tout le projet.
  const [retard] = await q<{ median: number; p90: number; n: number }>(`
    SELECT count(*)::int AS n,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY dernier_millesime - insee_date_eff)::int AS median,
           percentile_cont(0.9) WITHIN GROUP (ORDER BY dernier_millesime - insee_date_eff)::int AS p90
    FROM cad.disparition_validee WHERE insee_date_eff IS NOT NULL
  `)

  const couverture = await q<{ millesime: string; cadastre: number; insee: number }>(`
    SELECT m.millesime::text,
           (SELECT count(*)::int FROM cad.observation o WHERE o.millesime = m.millesime) AS cadastre,
           (SELECT count(*)::int FROM insee.commune_depuis_1943 c
             WHERE c.typecom='COM' AND c.date_debut <= m.millesime
               AND (c.date_fin IS NULL OR c.date_fin > m.millesime))                     AS insee
    FROM cad.millesime m ORDER BY m.millesime
  `)

  const anomalies = await q<{ regle: string; niveau: string; n: number }>(`
    SELECT regle, niveau, count(*)::int AS n FROM qa.anomalie GROUP BY 1,2 ORDER BY 1,2
  `)

  return { socle, evenements, retard, couverture, anomalies }
})
