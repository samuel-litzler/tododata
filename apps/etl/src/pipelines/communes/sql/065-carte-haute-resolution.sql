-- Palier haute résolution, servi à partir de z12.
-- Les paliers simplifiés restent indispensables aux petites échelles, mais au
-- zoom la simplification devient visible : un contour à 60 m dévie de ~1,5 pixel
-- à z12, et bien plus au-delà. Comme ST_AsMVTGeom découpe déjà par tuile, servir
-- la pleine résolution ne coûte presque rien à ces niveaux.
ALTER TABLE carte.departement ADD COLUMN IF NOT EXISTS ligne_carte_full geometry(MultiLineString, 3857);
ALTER TABLE carte.region      ADD COLUMN IF NOT EXISTS ligne_carte_full geometry(MultiLineString, 3857);
ALTER TABLE carte.commune     ADD COLUMN IF NOT EXISTS geom_carte_full  geometry(MultiPolygon, 3857);

UPDATE carte.departement SET ligne_carte_full = ST_Multi(ST_Boundary(geom_carte));
UPDATE carte.region      SET ligne_carte_full = ST_Multi(ST_Boundary(
  ST_CollectionExtract(ST_MakeValid((SELECT ST_Buffer(ST_Union(d.geom_carte),0)
     FROM carte.departement d WHERE d.code_region = carte.region.code)), 3)));

-- Communes : on repart de la source brute, translatée comme les autres pour les DROM.
UPDATE carte.commune c
   SET geom_carte_full = ST_Multi(ST_Transform(ST_MakeValid(r.geom, 'method=structure'), 3857))
  FROM raw.communes_2026_06_01 r
 WHERE r.id = c.code_insee
   AND c.departement NOT IN (SELECT departement FROM carte.cartouche_drom);

WITH v AS (
  SELECT d.code AS dep, ct.cible_x - ST_XMin(d.geom) AS dx, ct.cible_y - ST_YMin(d.geom) AS dy
  FROM carte.departement d JOIN carte.cartouche_drom ct ON ct.departement = d.code)
UPDATE carte.commune c
   SET geom_carte_full = ST_Multi(ST_Translate(
         ST_Transform(ST_MakeValid(r.geom, 'method=structure'), 3857), v.dx, v.dy))
  FROM raw.communes_2026_06_01 r, v
 WHERE r.id = c.code_insee AND v.dep = c.departement;

CREATE INDEX IF NOT EXISTS commune_geom_full_gist   ON carte.commune     USING GIST (geom_carte_full);
CREATE INDEX IF NOT EXISTS dep_ligne_full_gist      ON carte.departement USING GIST (ligne_carte_full);
CREATE INDEX IF NOT EXISTS region_ligne_full_gist   ON carte.region      USING GIST (ligne_carte_full);
ANALYZE carte.commune; ANALYZE carte.departement; ANALYZE carte.region;
SELECT count(*) FILTER (WHERE geom_carte_full IS NOT NULL) AS communes_pleine_res,
       pg_size_pretty(pg_total_relation_size('carte.commune')) AS taille_table
FROM carte.commune;
