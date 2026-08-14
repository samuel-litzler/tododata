-- =============================================================================
-- 055 — Limites administratives pour la carte : régions et contours
-- =============================================================================
-- Deux besoins distincts :
--
-- 1. Garder les limites de départements et de régions visibles quand on zoome
--    sur les communes. Sans elles on perd tout repère : à z12 on ne sait plus
--    dans quel département on se trouve.
--
-- 2. Le faire sans écrouler la génération de tuiles. Découper le POLYGONE d'un
--    département à chaque tuile de z12 est coûteux — c'est une géométrie énorme.
--    On stocke donc le CONTOUR sous forme de lignes : le découpage d'une ligne
--    est très largement moins cher que celui d'un polygone, pour un rendu
--    identique puisqu'on ne veut de toute façon que le trait.
-- =============================================================================

-- --- Régions : union des départements qui les composent ----------------------
DROP TABLE IF EXISTS carte.region CASCADE;
CREATE TABLE carte.region AS
SELECT
  d.code_region                                AS code,
  max(d.region)                                AS nom,
  count(*)::int                                AS nb_departements,
  sum(d.nb_communes)::int                      AS nb_communes,
  sum(d.nb_absorbees)::int                     AS nb_absorbees,
  sum(d.km2)                                   AS km2,
  -- ST_Buffer(…, 0) recolle les micro-fentes entre départements voisins, sinon
  -- l'union laisse des artefacts filiformes visibles au zoom.
  ST_Multi(ST_Buffer(ST_Union(d.geom), 0))     AS geom
FROM carte.departement d
WHERE d.code_region IS NOT NULL
GROUP BY d.code_region;

ALTER TABLE carte.region ADD PRIMARY KEY (code);

-- Deux résolutions de contour. Sans la version grossière, la tuile de z4 pèse
-- 2,7 Mo : à l'échelle du pays, un trait suivant le détail côtier au mètre près
-- coûte des mégaoctets pour un résultat visuellement identique.
ALTER TABLE carte.region ADD COLUMN geom_ligne geometry(MultiLineString, 3857);
ALTER TABLE carte.region ADD COLUMN geom_ligne_low geometry(MultiLineString, 3857);
-- Simplification des contours : ST_ReducePrecision PUIS SimplifyPreserveTopology.
--
-- Les deux étapes sont nécessaires, et l'ordre compte :
--   — sans ReducePrecision, la simplification topologique ne retire presque rien
--     (819 392 points au lieu de 60 389) car l'union des communes laisse des
--     sommets quasi-dupliqués le long des frontières partagées, qu'elle refuse
--     de fusionner ;
--   — sans PreserveTopology, un ST_Simplify franc rend 91 départements sur 101
--     invalides (auto-intersections) et dessine à l'écran de longs segments qui
--     traversent la géométrie en ligne droite.
-- La combinaison donne 101/101 polygones valides pour 60 389 points.
UPDATE carte.region
   SET geom_ligne     = ST_Multi(ST_Boundary(ST_SimplifyPreserveTopology(geom, 80))),
       geom_ligne_low = ST_Multi(ST_Boundary(
                          ST_SimplifyPreserveTopology(ST_ReducePrecision(geom, 700), 1400)));

CREATE INDEX region_geom_gist ON carte.region USING GIST (geom);
CREATE INDEX region_ligne_gist ON carte.region USING GIST (geom_ligne);
CREATE INDEX region_ligne_low_gist ON carte.region USING GIST (geom_ligne_low);
ANALYZE carte.region;

-- --- Contours départementaux -------------------------------------------------
ALTER TABLE carte.departement ADD COLUMN IF NOT EXISTS geom_ligne geometry(MultiLineString, 3857);
ALTER TABLE carte.departement ADD COLUMN IF NOT EXISTS geom_ligne_low geometry(MultiLineString, 3857);
UPDATE carte.departement
   SET geom_ligne     = ST_Multi(ST_Boundary(ST_SimplifyPreserveTopology(geom, 60))),
       geom_ligne_low = ST_Multi(ST_Boundary(
                          ST_SimplifyPreserveTopology(ST_ReducePrecision(geom, 500), 1000)));

-- Le polygone départemental sert d'aplat sur la vue d'ensemble. Non simplifié,
-- il pèse à lui seul 2,3 Mo dans la tuile de z4 : c'est lui, et non les
-- contours, qui dominait le poids.
ALTER TABLE carte.departement ADD COLUMN IF NOT EXISTS geom_low geometry(MultiPolygon, 3857);
-- ST_Simplify et NON ST_SimplifyPreserveTopology : l'union des communes laisse
-- des sommets quasi-dupliqués le long des frontières partagées, que la variante
-- topologique refuse de fusionner. Mesuré : 758 812 points contre 26 064.
-- ST_MakeValid + CollectionExtract récupèrent les polygones après une
-- simplification aussi franche, qui peut produire des géométries dégénérées.
UPDATE carte.departement
   SET geom_low = ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_Simplify(geom, 1500)), 3));
CREATE INDEX IF NOT EXISTS departement_geom_low_gist ON carte.departement USING GIST (geom_low);

CREATE INDEX IF NOT EXISTS departement_ligne_gist ON carte.departement USING GIST (geom_ligne);
CREATE INDEX IF NOT EXISTS departement_ligne_low_gist ON carte.departement USING GIST (geom_ligne_low);
ANALYZE carte.departement;
