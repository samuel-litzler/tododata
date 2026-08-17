/**
 * Toute la vie parcellaire d'une commune, en une seule réponse.
 *
 * Le parti pris est celui d'un curseur qui doit répondre à la milliseconde :
 * l'utilisateur balaie la frise d'avant en arrière, et une requête réseau par
 * position rendrait le geste poisseux. On envoie donc TOUTES les versions d'un
 * coup, chacune bornée par les deux relevés entre lesquels elle a existé, et le
 * navigateur ne fait plus que filtrer.
 *
 * Ça n'est tenable que parce que le découpage par commune est petit : ~2 100
 * parcelles en moyenne en Moselle, et le modèle de versions fait qu'une parcelle
 * inchangée depuis 2018 ne pèse qu'UNE géométrie, pas trente-deux.
 *
 * Les bornes sont des INDICES dans le tableau des relevés, pas des dates : sur
 * plusieurs milliers d'entités, deux petits entiers pèsent bien moins que deux
 * chaînes ISO, et le filtre côté client se réduit à une comparaison numérique.
 *
 * LE DOCUMENT EST ASSEMBLÉ PAR POSTGRES, et renvoyé tel quel. Faire remonter les
 * géométries en objets JavaScript pour les re-sérialiser ensuite coûtait double :
 * un parse et un stringify de plusieurs milliers de polygones à chaque appel — et
 * en développement, le sérialiseur de Nitro indente le résultat, ce qui gonflait
 * la réponse de 2,5 Mo à 9,5 Mo pour une commune moyenne. On produit donc le
 * texte final directement en SQL.
 */
export default defineEventHandler(async (event) => {
  const code = getRouterParam(event, 'code')
  if (!code || !/^[0-9AB]{5}$/i.test(code)) {
    throw createError({ statusCode: 400, statusMessage: 'Code commune invalide' })
  }
  const departement = code.slice(0, 2)

  const releves = await q<{ millesime: string }>(
    `SELECT to_char(millesime, 'YYYY-MM-DD') AS millesime
       FROM parc.millesime WHERE departement = $1 ORDER BY millesime`,
    [departement],
  )

  if (releves.length === 0) {
    throw createError({
      statusCode: 404,
      statusMessage: "Les parcelles de ce département n'ont pas encore été relevées",
    })
  }

  const [ligne] = await q<{ document: string }>(
    `
    WITH releve AS (
      SELECT millesime,
             (row_number() OVER (ORDER BY millesime) - 1)::int AS rang
        FROM parc.millesime WHERE departement = $2
    ),
    entites AS (
      SELECT jsonb_build_object(
               'type', 'Feature',
               -- Simplification calée sur la tolérance de détection des
               -- changements (25 cm) : afficher un tracé plus fin que celui au
               -- niveau duquel on prétend distinguer un mouvement serait une
               -- précision de façade. Divise le poids par deux.
               'geometry', ST_AsGeoJSON(
                             ST_SimplifyPreserveTopology(v.geom, 0.0000025), 6
                           )::jsonb,
               'properties', jsonb_build_object(
                 'id',         v.id_parcelle,
                 'section',    v.section,
                 'numero',     v.numero,
                 'prefixe',    v.prefixe,
                 'contenance', v.contenance,
                 -- Surface mesurée sur le tracé, arrondie au m² : la frise en
                 -- fait des totaux par relevé, les décimales n'y survivraient pas
                 -- et alourdiraient la réponse de plusieurs centaines de Ko.
                 'surface',    round(v.surface_m2)::int,
                 'debut',      rd.rang,
                 -- 'fin' à null = encore présente au dernier relevé. On garde la
                 -- distinction avec une fin qui tomberait sur ce même relevé.
                 'fin',        rf.rang,
                 -- Sans ces deux drapeaux, la fin d'une version est ambiguë :
                 -- elle signifie soit que la parcelle a disparu, soit qu'elle
                 -- vient d'être redessinée et qu'une version lui succède. La
                 -- frise doit distinguer les deux — c'est toute la différence
                 -- entre « ce terrain a cessé d'exister » et « il a été remanié ».
                 'premiere',   v.no_version = 1,
                 'derniere',   NOT EXISTS (SELECT 1 FROM parc.version s
                                            WHERE s.id_parcelle = v.id_parcelle
                                              AND s.no_version > v.no_version)
               )
             ) AS f
        FROM parc.version v
        JOIN releve rd ON rd.millesime = v.vu_debut
        LEFT JOIN releve rf ON rf.millesime = v.vu_fin
       WHERE v.commune = $1
    )
    SELECT jsonb_build_object(
             'code', $1::text,
             'millesimes', (SELECT jsonb_agg(to_char(millesime, 'YYYY-MM-DD') ORDER BY millesime)
                              FROM parc.millesime WHERE departement = $2),
             'parcelles', jsonb_build_object(
               'type', 'FeatureCollection',
               'features', coalesce((SELECT jsonb_agg(f) FROM entites), '[]'::jsonb)
             )
           )::text AS document
  `,
    [code.toUpperCase(), departement],
  )

  // Les données ne bougent qu'à l'ingestion, mais le curseur va rejouer la même
  // commune souvent : un cache court suffit à absorber les allers-retours.
  setHeader(event, 'Cache-Control', 'public, max-age=300')
  setHeader(event, 'Content-Type', 'application/json; charset=utf-8')
  // Renvoyé en texte brut : passer par un objet ferait re-sérialiser à Nitro ce
  // que Postgres a déjà écrit.
  return ligne?.document ?? '{}'
})
