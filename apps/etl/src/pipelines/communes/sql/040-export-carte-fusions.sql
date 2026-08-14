-- =============================================================================
-- 040 — Export des territoires historiques pour la carte des fusions
-- =============================================================================
-- Idée centrale : le PRÉFIXE de section cadastral porte le numéro de l'ancienne
-- commune absorbée. La géométrie des communes disparues est donc encore présente
-- dans le cadastre ACTUEL, découpée en groupes de sections.
--
-- Mesuré sur le millésime 2026-06-01 :
--   37 730 préfixes sur 34 916 communes
--    2 831 préfixes ≠ '000' = autant de territoires absorbés, sur 1 370 communes
--    2 666 (94 %) correspondent à un code reconnu par le COG depuis 1943
--        0 ne correspond à une commune encore vivante en 2026
--
-- Deux précautions :
--   1. 4 955 géométries de la couche sont invalides (13 %) : ST_MakeValid en
--      'method=structure' est obligatoire (d'où l'exigence GEOS >= 3.10).
--   2. Marseille utilise des préfixes 801-816 qui sont des quartiers cadastraux,
--      PAS des codes communes. On les exclut du rapprochement INSEE.
-- =============================================================================

\set ON_ERROR_STOP on

WITH base AS (
  SELECT
    p.commune,
    p.prefixe,
    nullif(p.ancienne,'')                                                        AS ancienne,
    nullif(p.nom,'')                                                             AS nom_cadastre,
    (CASE WHEN p.commune ~ '^97' THEN substr(p.commune,1,3)
          ELSE substr(p.commune,1,2) END) || p.prefixe                           AS code_reconstitue,
    ST_MakeValid(p.geom, 'method=structure')                                     AS geom
  FROM raw.prefixes_sections_2026_06_01 p
  WHERE p.commune IN (SELECT commune FROM raw.prefixes_sections_2026_06_01 WHERE prefixe <> '000')
),
enrichi AS (
  SELECT
    b.*,
    -- Le libellé officiel du code reconstitué, s'il est connu du COG historique.
    (SELECT i.libelle FROM insee.commune_depuis_1943 i
      WHERE i.com = b.code_reconstitue AND i.typecom = 'COM'
      ORDER BY i.date_debut DESC LIMIT 1)                                        AS nom_insee,
    (SELECT min(i.date_debut) FROM insee.commune_depuis_1943 i
      WHERE i.com = b.code_reconstitue AND i.typecom = 'COM')                    AS insee_debut,
    (SELECT max(i.date_fin) FROM insee.commune_depuis_1943 i
      WHERE i.com = b.code_reconstitue AND i.typecom = 'COM')                    AS insee_fin,
    -- La date de fusion actée par l'INSEE vers la commune porteuse, si elle existe.
    (SELECT max(v.date_eff) FROM insee.mvt_commune v
      WHERE v.com_av = b.code_reconstitue AND v.com_ap = b.commune)              AS fusion_le,
    round((ST_Area(b.geom::geography)/1e6)::numeric, 2)                          AS km2
  FROM base b
)
SELECT json_build_object(
  'commune',  e.commune,
  'nom',      (SELECT o.nom FROM cad.observation o
                WHERE o.code_insee = e.commune ORDER BY o.millesime DESC LIMIT 1),
  'nom_cog',  (SELECT i.libelle FROM insee.commune_depuis_1943 i
                WHERE i.com = e.commune AND i.typecom='COM'
                ORDER BY i.date_debut DESC LIMIT 1),
  'parts', json_agg(json_build_object(
      'prefixe',  e.prefixe,
      -- Trois natures distinctes, à ne pas confondre :
      --   noyau      : le préfixe '000', territoire d'origine de la commune
      --   absorbee   : le préfixe est un n° de commune reconnu par le COG depuis 1943
      --   quartier   : le préfixe est une subdivision cadastrale interne, PAS une
      --                ancienne commune. 165 cas, concentrés sur Marseille et
      --                Toulouse (plages 8xx et 9xx). Les afficher comme
      --                « dénomination inconnue » était trompeur.
      'nature',   CASE
                    WHEN e.prefixe = '000'      THEN 'noyau'
                    WHEN e.nom_insee IS NOT NULL THEN 'absorbee'
                    ELSE 'quartier' END,
      'code',     CASE WHEN e.prefixe = '000' THEN NULL
                       WHEN e.nom_insee IS NULL THEN NULL  -- pas un code commune
                       ELSE e.code_reconstitue END,
      'nom',      coalesce(e.nom_insee, e.nom_cadastre),
      'ancienne', e.ancienne,
      'debut',    e.insee_debut,
      'fin',      e.insee_fin,
      'fusion',   e.fusion_le,
      'km2',      e.km2,
      'geom',     ST_AsGeoJSON(ST_SimplifyPreserveTopology(e.geom, 0.0003), 5)::json
    ) ORDER BY e.prefixe)
)
FROM enrichi e
GROUP BY e.commune
ORDER BY e.commune;
