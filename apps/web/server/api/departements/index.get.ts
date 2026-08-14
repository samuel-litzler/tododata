/** Liste des départements, pour la navigation et la page d'index. */
export default defineEventHandler(async () =>
  q(`SELECT code, nom, nb_communes, nb_absorbees, km2,
            ST_X(ST_Centroid(ST_Transform(geom, 4326))) AS lon,
            ST_Y(ST_Centroid(ST_Transform(geom, 4326))) AS lat
       FROM carte.departement ORDER BY code`),
)
