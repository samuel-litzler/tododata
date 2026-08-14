-- =============================================================================
-- 060 — Rapprochement cartographique des DROM
-- =============================================================================
-- Les départements d'outre-mer sont à des milliers de kilomètres : sur une carte
-- au vrai positionnement, ils sont invisibles tant qu'on regarde la métropole,
-- et inversement. La convention cartographique française consiste à les déplacer
-- dans des cartouches à côté de l'Hexagone.
--
-- On introduit donc une géométrie D'AFFICHAGE, distincte de la géométrie réelle :
--   geom        position géographique vraie — sert aux calculs (surfaces, voisinage)
--   geom_carte  position d'affichage — identique pour la métropole, translatée
--               pour les DROM
--
-- L'ÉCHELLE EST PRÉSERVÉE : on translate, on ne redimensionne pas. La Guyane
-- reste donc grande (84 213 km², soit plus que l'Aquitaine) — c'est voulu, la
-- réduire mentirait sur la réalité du territoire.
--
-- La translation se fait en Web Mercator, où les distances sont déjà déformées
-- par la latitude. C'est sans conséquence : ces géométries ne servent qu'au
-- rendu, jamais à une mesure. Toute surface se calcule depuis `geom`.
-- =============================================================================

-- Emprise de la métropole (Web Mercator) : x ≈ -572 812 → 1 064 203,
-- y ≈ 5 061 656 → 6 637 034. On empile les cartouches dans l'Atlantique, à
-- l'ouest, en respectant les proportions relatives des territoires.
DROP TABLE IF EXISTS carte.cartouche_drom;
CREATE TABLE carte.cartouche_drom (
  departement text PRIMARY KEY,
  -- coin inférieur gauche du cartouche, en Web Mercator
  cible_x     double precision NOT NULL,
  cible_y     double precision NOT NULL
);

INSERT INTO carte.cartouche_drom (departement, cible_x, cible_y) VALUES
  -- colonne de gauche, du nord au sud, avec une gouttière de ~60 km
  ('971', -1500000, 6280000),   -- Guadeloupe
  ('972', -1500000, 6120000),   -- Martinique
  ('976', -1500000, 5980000),   -- Mayotte
  ('974', -1500000, 5820000),   -- La Réunion
  -- la Guyane est trop vaste pour la colonne : elle prend le bas du cadre
  ('973', -1500000, 5100000);

-- --- Communes ----------------------------------------------------------------
ALTER TABLE carte.commune ADD COLUMN IF NOT EXISTS geom_carte geometry(MultiPolygon, 3857);
ALTER TABLE carte.commune ADD COLUMN IF NOT EXISTS geom_carte_low geometry(MultiPolygon, 3857);

-- Métropole : la géométrie d'affichage est la géométrie réelle.
UPDATE carte.commune
   SET geom_carte = geom, geom_carte_low = geom_low
 WHERE departement NOT IN (SELECT departement FROM carte.cartouche_drom);

-- DROM : translation par le vecteur qui amène le coin inférieur gauche du
-- département sur celui de son cartouche. Le vecteur est calculé UNE FOIS par
-- département, sinon chaque commune se recalerait indépendamment et le
-- département exploserait.
WITH v AS (
  SELECT d.code AS departement,
         c.cible_x - ST_XMin(d.geom) AS dx,
         c.cible_y - ST_YMin(d.geom) AS dy
  FROM carte.departement d
  JOIN carte.cartouche_drom c ON c.departement = d.code
)
UPDATE carte.commune cm
   SET geom_carte     = ST_Multi(ST_Translate(cm.geom, v.dx, v.dy)),
       geom_carte_low = ST_Multi(ST_Translate(cm.geom_low, v.dx, v.dy))
  FROM v WHERE v.departement = cm.departement;

CREATE INDEX IF NOT EXISTS commune_geom_carte_gist ON carte.commune USING GIST (geom_carte);
CREATE INDEX IF NOT EXISTS commune_geom_carte_low_gist ON carte.commune USING GIST (geom_carte_low);

-- --- Départements ------------------------------------------------------------
ALTER TABLE carte.departement ADD COLUMN IF NOT EXISTS geom_carte geometry(MultiPolygon, 3857);
ALTER TABLE carte.departement ADD COLUMN IF NOT EXISTS geom_carte_low geometry(MultiPolygon, 3857);
ALTER TABLE carte.departement ADD COLUMN IF NOT EXISTS ligne_carte geometry(MultiLineString, 3857);
ALTER TABLE carte.departement ADD COLUMN IF NOT EXISTS ligne_carte_low geometry(MultiLineString, 3857);

UPDATE carte.departement
   SET geom_carte = geom, geom_carte_low = geom_low,
       ligne_carte = geom_ligne, ligne_carte_low = geom_ligne_low
 WHERE code NOT IN (SELECT departement FROM carte.cartouche_drom);

WITH v AS (
  SELECT d.code, c.cible_x - ST_XMin(d.geom) AS dx, c.cible_y - ST_YMin(d.geom) AS dy
  FROM carte.departement d JOIN carte.cartouche_drom c ON c.departement = d.code
)
UPDATE carte.departement d
   SET geom_carte      = ST_Multi(ST_Translate(d.geom, v.dx, v.dy)),
       geom_carte_low  = ST_Multi(ST_Translate(d.geom_low, v.dx, v.dy)),
       ligne_carte     = ST_Multi(ST_Translate(d.geom_ligne, v.dx, v.dy)),
       ligne_carte_low = ST_Multi(ST_Translate(d.geom_ligne_low, v.dx, v.dy))
  FROM v WHERE v.code = d.code;

CREATE INDEX IF NOT EXISTS departement_geom_carte_gist ON carte.departement USING GIST (geom_carte);
CREATE INDEX IF NOT EXISTS departement_geom_carte_low_gist ON carte.departement USING GIST (geom_carte_low);
CREATE INDEX IF NOT EXISTS departement_ligne_carte_gist ON carte.departement USING GIST (ligne_carte);
CREATE INDEX IF NOT EXISTS departement_ligne_carte_low_gist ON carte.departement USING GIST (ligne_carte_low);

-- --- Régions -----------------------------------------------------------------
-- Chaque DROM est sa propre région : on reconstruit depuis les départements
-- déjà translatés plutôt que de recalculer un vecteur.
ALTER TABLE carte.region ADD COLUMN IF NOT EXISTS ligne_carte geometry(MultiLineString, 3857);
ALTER TABLE carte.region ADD COLUMN IF NOT EXISTS ligne_carte_low geometry(MultiLineString, 3857);

WITH u AS (
  SELECT d.code_region,
         ST_Buffer(ST_Union(d.geom_carte_low), 0) AS g
  FROM carte.departement d WHERE d.code_region IS NOT NULL
  GROUP BY d.code_region
)
UPDATE carte.region r
   SET ligne_carte     = ST_Multi(ST_Boundary(ST_CollectionExtract(ST_MakeValid(u.g), 3))),
       ligne_carte_low = ST_Multi(ST_Boundary(
                           ST_CollectionExtract(ST_MakeValid(ST_Simplify(u.g, 2500)), 3)))
  FROM u WHERE u.code_region = r.code;

CREATE INDEX IF NOT EXISTS region_ligne_carte_gist ON carte.region USING GIST (ligne_carte);
CREATE INDEX IF NOT EXISTS region_ligne_carte_low_gist ON carte.region USING GIST (ligne_carte_low);

ANALYZE carte.commune;
ANALYZE carte.departement;
ANALYZE carte.region;
