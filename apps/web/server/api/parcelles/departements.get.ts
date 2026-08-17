/**
 * Les départements dont le parcellaire a été relevé.
 *
 * L'ingestion parcellaire se fait département par département et prend du temps :
 * le site doit donc savoir ce qui est disponible plutôt que de proposer un lien
 * qui mènerait à une page vide.
 */
export default defineEventHandler(async (event) => {
  const rows = await q<{ departement: string; n: number; dernier: string }>(
    `SELECT departement,
            count(*)::int AS n,
            to_char(max(millesime), 'YYYY-MM-DD') AS dernier
       FROM parc.millesime
      GROUP BY departement
      ORDER BY departement`,
  )

  // L'ingestion est en cours pendant que le site tourne : un cache long ferait
  // croire que rien n'avance.
  setHeader(event, 'Cache-Control', 'public, max-age=60')

  return rows
})
