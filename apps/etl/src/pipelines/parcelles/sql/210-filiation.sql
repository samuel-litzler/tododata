-- =============================================================================
-- nexus-analytics — filiation entre parcelles
-- =============================================================================
-- Une parcelle qui disparaît ne s'évapore pas : son sol reste, sous un autre
-- identifiant. Reconstituer ce lien, c'est le pendant parcellaire du graphe de
-- fusions des communes — et la seule façon de suivre « la vie » d'un terrain
-- au-delà du changement de numéro.
--
-- On distingue deux régimes, et on ne les mélange pas :
--
--   Renumérotation — la géométrie est RIGOUREUSEMENT identique, seul
--     l'identifiant change. C'est un fait, pas une déduction : les deux
--     parcelles partagent la même empreinte de contenu. L'égalité stricte est
--     ici légitime alors qu'elle ne l'est pas entre deux relevés — les deux
--     géométries sortent du MÊME fichier, le bruit de republication qui interdit
--     de comparer un relevé à l'autre ne joue pas à l'intérieur d'un relevé.
--     Cause principale : la fusion de communes, qui déplace les parcelles sous
--     un préfixe non-'000'.
--
--   Recomposition — la géométrie change (division, réunion, remaniement). Le
--     lien est alors une DÉDUCTION géométrique, fondée sur le recouvrement des
--     surfaces. On la marque comme telle, avec son taux de recouvrement, pour
--     que le site puisse distinguer ce qu'il sait de ce qu'il suppose.
--
-- Note de mise en œuvre : les deux populations sont matérialisées dans des
-- tables indexées, et non laissées en CTE. Un croisement spatial entre deux CTE
-- n'a aucun index à se mettre sous la dent — Postgres retomberait sur une boucle
-- imbriquée de plusieurs centaines de millions de comparaisons.
-- =============================================================================

-- Le recouvrement se calcule en projection métrique (parc.srid_metrique) : en
-- degrés, ST_Area donne des surfaces sans signification et le rapport serait
-- faux dès qu'on change de latitude.

-- --------------------------------------------------------------------------
-- Parcelles disparues, avec leur DERNIÈRE géométrie connue.
-- --------------------------------------------------------------------------
DROP TABLE IF EXISTS raw.filiation_partantes;
CREATE UNLOGGED TABLE raw.filiation_partantes AS
SELECT e.millesime,
       e.id_parcelle AS id,
       parc.departement_de(v.commune) AS departement,
       v.sha,
       v.geom,
       ST_Area(ST_Transform(v.geom, parc.srid_metrique(parc.departement_de(v.commune)))) AS aire
  FROM parc.evenement e
  JOIN parc.version   v ON v.id_parcelle = e.id_parcelle AND v.no_version = e.no_version
 WHERE e.type = 'disparition';

-- --------------------------------------------------------------------------
-- Parcelles apparues, avec leur PREMIÈRE géométrie.
-- --------------------------------------------------------------------------
DROP TABLE IF EXISTS raw.filiation_arrivantes;
CREATE UNLOGGED TABLE raw.filiation_arrivantes AS
SELECT e.millesime,
       e.id_parcelle AS id,
       parc.departement_de(v.commune) AS departement,
       v.sha,
       v.geom,
       ST_Area(ST_Transform(v.geom, parc.srid_metrique(parc.departement_de(v.commune)))) AS aire
  FROM parc.evenement e
  JOIN parc.version   v ON v.id_parcelle = e.id_parcelle AND v.no_version = e.no_version
 WHERE e.type = 'apparition';

CREATE INDEX ON raw.filiation_partantes  USING GIST (geom);
CREATE INDEX ON raw.filiation_arrivantes USING GIST (geom);
-- Départementalisé : sans cette clé, le croisement national confronterait les
-- disparitions de tout le pays aux apparitions de tout le pays pour un même
-- relevé. Le GIST écarterait bien les paires lointaines, mais après avoir été
-- interrogé des milliards de fois pour rien. Une filiation ne franchit jamais
-- une frontière départementale : le cadastre renumérote à l'intérieur d'un
-- département, jamais d'un département à l'autre.
CREATE INDEX ON raw.filiation_partantes  (departement, millesime);
CREATE INDEX ON raw.filiation_arrivantes (departement, millesime);
ANALYZE raw.filiation_partantes;
ANALYZE raw.filiation_arrivantes;

DROP TABLE IF EXISTS parc.filiation;
CREATE TABLE parc.filiation (
  millesime        date    NOT NULL,
  id_avant         text    NOT NULL,
  id_apres         text    NOT NULL,
  type             text    NOT NULL,   -- renumerotation | division | reunion | redecoupage
  -- Part de l'ancienne parcelle retrouvée dans la nouvelle, et réciproquement.
  -- 1.0 / 1.0 = même sol. 0.25 / 1.0 = la nouvelle est un quart de l'ancienne.
  part_avant       double precision,
  part_apres       double precision,
  -- true quand l'empreinte de contenu est identique : le lien est alors constaté,
  -- pas déduit. C'est ce drapeau que le site doit refléter.
  certain          boolean NOT NULL
);

WITH croisement AS (
  -- Restreint au MÊME relevé : une filiation ne peut relier que ce qui s'en va
  -- et ce qui arrive au même moment. Le GIST fait le gros du tri, seules les
  -- paires dont les emprises se recoupent atteignent le ST_Intersection.
  SELECT d.millesime,
         d.id AS id_avant,
         a.id AS id_apres,
         (d.sha = a.sha) AS meme_empreinte,
         d.aire AS aire_avant,
         a.aire AS aire_apres,
         ST_Area(ST_Transform(
           ST_Intersection(ST_MakeValid(d.geom), ST_MakeValid(a.geom)),
           parc.srid_metrique(parc.departement_de(d.id)))) AS aire_commune
    FROM raw.filiation_partantes d
    JOIN raw.filiation_arrivantes a
      ON a.departement = d.departement
     AND a.millesime = d.millesime
     AND d.geom && a.geom
     AND ST_Intersects(d.geom, a.geom)
),
-- Un simple contact de bordure entre deux voisines produit une intersection de
-- surface nulle ou dérisoire. On exige 5% d'un des deux côtés pour parler de
-- filiation.
retenu AS (
  SELECT *,
         aire_commune / nullif(aire_avant, 0) AS part_avant,
         aire_commune / nullif(aire_apres, 0) AS part_apres
    FROM croisement
   WHERE aire_commune > 0
     AND (aire_commune / nullif(aire_avant, 0) > 0.05
       OR aire_commune / nullif(aire_apres, 0) > 0.05)
),
-- La cardinalité de chaque côté est ce qui NOMME l'événement : une parcelle qui
-- a plusieurs successeurs a été divisée, plusieurs prédécesseurs pour une seule
-- arrivante signent une réunion.
cardinal AS (
  SELECT r.*,
         count(*) OVER (PARTITION BY r.millesime, r.id_avant) AS n_successeurs,
         count(*) OVER (PARTITION BY r.millesime, r.id_apres) AS n_predecesseurs
    FROM retenu r
)
INSERT INTO parc.filiation (
  millesime, id_avant, id_apres, type, part_avant, part_apres, certain
)
SELECT millesime, id_avant, id_apres,
       CASE
         WHEN meme_empreinte                            THEN 'renumerotation'
         WHEN n_successeurs > 1 AND n_predecesseurs = 1 THEN 'division'
         WHEN n_predecesseurs > 1 AND n_successeurs = 1 THEN 'reunion'
         ELSE 'redecoupage'
       END,
       part_avant, part_apres,
       meme_empreinte
  FROM cardinal;

CREATE INDEX ON parc.filiation (id_avant);
CREATE INDEX ON parc.filiation (id_apres);
CREATE INDEX ON parc.filiation (millesime, type);
ANALYZE parc.filiation;

DROP TABLE IF EXISTS raw.filiation_partantes;
DROP TABLE IF EXISTS raw.filiation_arrivantes;
