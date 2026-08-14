/**
 * Recherche par code INSEE ou par nom.
 *
 * Le nom cadastral est en capitales non accentuées et plafonné à 30 caractères ;
 * le libellé du COG est proprement accentué. On cherche donc sur les deux, via
 * unaccent, et on affiche le libellé officiel.
 */
export default defineEventHandler(async (event) => {
  const { q: terme = '' } = getQuery(event) as { q?: string }
  const t = terme.trim()

  if (!t) {
    // Sans terme : les communes qui ont le plus absorbé, c'est-à-dire les plus
    // intéressantes à ouvrir en premier.
    return q(`
      SELECT p.commune AS code,
             coalesce(ci.libelle, max(o.nom)) AS nom,
             count(*) FILTER (WHERE p.prefixe <> '000')::int AS absorbees
      FROM raw.prefixes_sections_2026_06_01 p
      LEFT JOIN insee.commune_2026 ci ON ci.com = p.commune AND ci.typecom = 'COM'
      LEFT JOIN cad.observation o ON o.code_insee = p.commune
      GROUP BY p.commune, ci.libelle
      HAVING count(*) FILTER (WHERE p.prefixe <> '000') > 0
      ORDER BY absorbees DESC, p.commune
      LIMIT 80
    `)
  }

  return q(
    `
    WITH cible AS (
      SELECT DISTINCT o.code_insee AS code,
             coalesce(ci.libelle, (SELECT nom FROM cad.observation x
                                    WHERE x.code_insee = o.code_insee
                                    ORDER BY x.millesime DESC LIMIT 1)) AS nom
      FROM cad.observation o
      LEFT JOIN insee.commune_2026 ci ON ci.com = o.code_insee AND ci.typecom = 'COM'
      WHERE o.code_insee LIKE $1 || '%'
         OR unaccent(upper(coalesce(ci.libelle, o.nom))) LIKE '%' || unaccent(upper($1)) || '%'
    )
    SELECT c.code, c.nom,
           (SELECT count(*) FILTER (WHERE p.prefixe <> '000')::int
              FROM raw.prefixes_sections_2026_06_01 p WHERE p.commune = c.code) AS absorbees
    FROM cible c
    -- un code exact d'abord, puis les noms les plus courts (donc les plus proches)
    ORDER BY (c.code = $1) DESC, (c.code LIKE $1 || '%') DESC, length(c.nom), c.code
    LIMIT 60
  `,
    [t],
  )
})
