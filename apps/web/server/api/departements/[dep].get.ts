/** Un département et ses communes, triées par nombre d'absorptions. */
export default defineEventHandler(async (event) => {
  const dep = getRouterParam(event, 'dep')
  if (!dep || !/^(2A|2B|9[7-8][0-9]|[0-9]{2})$/i.test(dep)) {
    throw createError({ statusCode: 400, statusMessage: 'Code de département invalide' })
  }
  const d = dep.toUpperCase()

  const [entete] = await q(
    `SELECT code, nom, nb_communes, nb_absorbees, km2,
            ST_XMin(b) AS xmin, ST_YMin(b) AS ymin, ST_XMax(b) AS xmax, ST_YMax(b) AS ymax
       FROM carte.departement, LATERAL (SELECT ST_Envelope(ST_Transform(geom, 4326)) AS b) e
      WHERE code = $1`,
    [d],
  )
  if (!entete) throw createError({ statusCode: 404, statusMessage: `Département ${d} inconnu` })

  const communes = await q(
    `SELECT code_insee AS code, nom, km2, nb_absorbees
       FROM carte.commune WHERE departement = $1
      ORDER BY nb_absorbees DESC, nom`,
    [d],
  )

  return { entete, communes }
})
