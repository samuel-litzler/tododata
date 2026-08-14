-- =============================================================================
-- 050 — Table de rendu cartographique, pour les tuiles vectorielles
-- =============================================================================
-- Les tuiles sont générées à la volée par ST_AsMVT depuis Postgres : aucun build
-- de tuiles à maintenir, et la carte reflète toujours l'état réel de la base.
--
-- Trois décisions qui conditionnent la fluidité :
--
-- 1. Reprojection en 3857 une fois pour toutes. ST_AsMVTGeom attend la géométrie
--    et l'enveloppe de tuile dans le même SRID ; reprojeter à chaque requête de
--    tuile coûterait bien plus cher que de stocker la colonne.
--
-- 2. Deux niveaux de détail. Les contours cadastraux suivent le tracé parcellaire :
--    à l'échelle de la France, c'est des dizaines de millions de points inutiles.
--    On pré-simplifie donc à deux tolérances et on choisit selon le zoom.
--
-- 3. ST_MakeValid systématique. 13 % des géométries de la couche des préfixes sont
--    invalides à la source, et les communes ne sont pas exemptes ; une géométrie
--    invalide fait échouer ST_AsMVTGeom sur toute la tuile, pas seulement sur
--    l'objet fautif.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS carte;

DROP TABLE IF EXISTS carte.commune;
CREATE TABLE carte.commune (
  code_insee   text PRIMARY KEY,
  nom          text NOT NULL,
  departement  text NOT NULL,
  -- Nombre de territoires historiques absorbés : sert à colorer la carte, et
  -- c'est l'information qui donne envie de cliquer.
  nb_absorbees integer NOT NULL DEFAULT 0,
  km2          numeric(10, 2),
  -- z >= 9 : détail fin (~20 m). z < 9 : silhouette (~200 m).
  geom         geometry(MultiPolygon, 3857) NOT NULL,
  geom_low     geometry(MultiPolygon, 3857) NOT NULL
);

INSERT INTO carte.commune (code_insee, nom, departement, nb_absorbees, km2, geom, geom_low)
SELECT
  c.id,
  coalesce(i.libelle, c.nom, c.id),
  CASE WHEN c.id ~ '^97' THEN substr(c.id, 1, 3) ELSE substr(c.id, 1, 2) END,
  coalesce(a.n, 0),
  round((ST_Area(c.geom::geography) / 1e6)::numeric, 2),
  ST_Multi(ST_SimplifyPreserveTopology(ST_Transform(ST_MakeValid(c.geom, 'method=structure'), 3857), 20)),
  ST_Multi(ST_SimplifyPreserveTopology(ST_Transform(ST_MakeValid(c.geom, 'method=structure'), 3857), 200))
FROM raw.communes_2026_06_01 c
LEFT JOIN insee.commune_2026 i ON i.com = c.id AND i.typecom = 'COM'
LEFT JOIN (
  SELECT p.commune, count(*)::int AS n
  FROM raw.prefixes_sections_2026_06_01 p
  WHERE p.prefixe <> '000'
    -- seuls les préfixes correspondant à un vrai code commune comptent : les
    -- plages 8xx/9xx de Marseille et Toulouse sont des quartiers cadastraux
    AND EXISTS (
      SELECT 1 FROM insee.commune_depuis_1943 x
      WHERE x.typecom = 'COM'
        AND x.com = (CASE WHEN p.commune ~ '^97' THEN substr(p.commune, 1, 3)
                          ELSE substr(p.commune, 1, 2) END) || p.prefixe
    )
  GROUP BY p.commune
) a ON a.commune = c.id
WHERE c.id IS NOT NULL AND c.geom IS NOT NULL;

-- Un index GIST par niveau de détail : la requête de tuile filtre sur
-- l'intersection avec l'enveloppe, c'est le seul accès qui compte.
CREATE INDEX commune_geom_gist ON carte.commune USING GIST (geom);
CREATE INDEX commune_geom_low_gist ON carte.commune USING GIST (geom_low);
CREATE INDEX commune_dep_idx ON carte.commune (departement);
ANALYZE carte.commune;

-- --- Agrégat départemental, pour la vue d'ensemble et les pages /departements --
DROP TABLE IF EXISTS carte.departement;
CREATE TABLE carte.departement AS
SELECT
  c.departement                                AS code,
  -- Le vrai libellé vient du référentiel INSEE (migration 005). Sans lui on
  -- n'aurait que « 74 » à afficher, illisible pour un visiteur.
  coalesce(max(d.libelle), c.departement)      AS nom,
  max(r.libelle)                               AS region,
  max(d.reg)                                   AS code_region,
  count(*)::int                                AS nb_communes,
  sum(c.nb_absorbees)::int                     AS nb_absorbees,
  round(sum(c.km2), 0)                         AS km2,
  ST_Multi(ST_Buffer(ST_Union(c.geom_low), 0)) AS geom
FROM carte.commune c
LEFT JOIN insee.departement d ON d.dep = c.departement
LEFT JOIN insee.region r ON r.reg = d.reg
GROUP BY c.departement;

ALTER TABLE carte.departement ADD PRIMARY KEY (code);
CREATE INDEX departement_geom_gist ON carte.departement USING GIST (geom);
ANALYZE carte.departement;
