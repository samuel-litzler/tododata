/**
 * Inventaire des codes INSEE : ceux qui désignent une commune aujourd'hui, et
 * ceux qui en ont désigné une autrefois.
 *
 * Un code n'est pas un identifiant stable. Il naît, il sert, il s'éteint —
 * et cette page est la vue la plus directe de ce fait.
 */
export default defineEventHandler(async (event) => {
  const { dep, etat = 'tous', q: terme = '' } = getQuery(event) as {
    dep?: string
    etat?: 'tous' | 'actifs' | 'eteints'
    q?: string
  }

  const filtres: string[] = []
  const params: unknown[] = []
  if (dep && /^(2A|2B|97[1-8]|[0-9]{2})$/i.test(dep)) {
    params.push(dep.toUpperCase())
    filtres.push(`departement = $${params.length}`)
  }
  if (terme.trim()) {
    params.push(terme.trim())
    filtres.push(
      `(code LIKE $${params.length} || '%' OR unaccent(upper(nom)) LIKE '%' || unaccent(upper($${params.length})) || '%')`,
    )
  }
  if (etat === 'actifs') filtres.push('actif')
  if (etat === 'eteints') filtres.push('NOT actif')
  const where = filtres.length ? `WHERE ${filtres.join(' AND ')}` : ''

  const base = `
    WITH tous AS (
      -- Les codes vivants : une commune les porte aujourd'hui.
      SELECT c.code_insee AS code, c.nom, c.departement, true AS actif,
             NULL::text AS fin, NULL::text AS repris_par
      FROM carte.commune c
      UNION ALL
      -- Les codes éteints : plus aucune commune ne les porte, mais le registre
      -- historique en garde la trace, et le cadastre en garde le territoire.
      SELECT i.com, i.libelle,
             CASE WHEN i.com ~ '^97' THEN substr(i.com,1,3) ELSE substr(i.com,1,2) END,
             false, max(i.date_fin)::text,
             (SELECT v.com_ap FROM insee.mvt_commune v
               WHERE v.com_av = i.com AND v.com_ap <> i.com
               ORDER BY v.date_eff DESC LIMIT 1)
      FROM insee.commune_depuis_1943 i
      WHERE i.typecom = 'COM'
        AND NOT EXISTS (SELECT 1 FROM carte.commune c WHERE c.code_insee = i.com)
      GROUP BY i.com, i.libelle
    )
    SELECT * FROM tous ${where}
  `

  const [totaux] = await q<{ actifs: number; eteints: number }>(
    `SELECT count(*) FILTER (WHERE actif)::int AS actifs,
            count(*) FILTER (WHERE NOT actif)::int AS eteints
       FROM (${base}) t`,
    params,
  )

  // Plafond volontaire : 40 000 lignes dans le DOM ne sert personne, et la
  // recherche est là pour ça.
  const lignes = await q(
    `SELECT * FROM (${base}) t ORDER BY code LIMIT 400`,
    params,
  )

  return { totaux, lignes, tronque: (totaux?.actifs ?? 0) + (totaux?.eteints ?? 0) > 400 }
})
