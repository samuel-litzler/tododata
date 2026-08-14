-- =============================================================================
-- 010 — Présence consolidée des communes, et traitement des trous de millésime
-- =============================================================================
-- Problème traité
-- ---------------
-- 95 codes INSEE disparaissent d'un ou plusieurs millésimes cadastraux puis
-- réapparaissent. Décision produit : ce sont des défauts de publication en amont,
-- on comble et on trace, sans chercher à les expliquer un par un.
--
-- MAIS on ne comble pas aveuglément : 4 de ces 95 trous correspondent à un
-- RÉTABLISSEMENT de commune réel (MOD 21 « Rétablissement », MOD 71
-- « Rétablissement de commune déléguée »). Les combler effacerait un événement
-- administratif authentique. Le critère de discrimination est double :
--   1. il existe un mouvement INSEE 21/71 aboutissant à ce code, ET
--   2. sa date d'effet tombe dans la fenêtre du trou (élargie d'un an en amont
--      pour absorber le retard médian du cadastre, mesuré à 273 jours).
--
-- Sortie : cad.presence, où chaque ligne porte l'origine de l'information
-- ('observee' vs 'comblee'). Tout le reste du modèle doit lire cette table et
-- non cad.observation, pour ne plus jamais retomber sur les faux
-- disparition/réapparition.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS qa;

-- --- 1. Les trous, avec leur fenêtre temporelle -----------------------------
DROP TABLE IF EXISTS qa.trou_millesime CASCADE;
CREATE TABLE qa.trou_millesime AS
WITH obs AS (
  SELECT o.code_insee, m.rang, m.millesime
  FROM cad.observation o JOIN cad.millesime m USING (millesime)
),
paires AS (
  SELECT code_insee,
         rang                                                              AS rang_avant,
         millesime                                                         AS vu_avant,
         lead(rang)      OVER (PARTITION BY code_insee ORDER BY rang)       AS rang_apres,
         lead(millesime) OVER (PARTITION BY code_insee ORDER BY rang)       AS vu_apres
  FROM obs
)
SELECT
  p.code_insee,
  p.vu_avant,
  p.vu_apres,
  p.rang_avant,
  p.rang_apres,
  (p.rang_apres - p.rang_avant - 1) AS millesimes_manquants,
  -- Le rétablissement INSEE qui expliquerait le trou, s'il existe.
  (SELECT min(v.date_eff) FROM insee.mvt_commune v
    WHERE v.com_ap = p.code_insee
      AND v.mod IN ('21','71')
      -- fenêtre élargie d'un an en amont : le cadastre a 273 j de retard médian
      AND v.date_eff >  p.vu_avant - INTERVAL '1 year'
      AND v.date_eff <= p.vu_apres
  ) AS retablissement_le
FROM paires p
WHERE p.rang_apres IS NOT NULL
  AND p.rang_apres > p.rang_avant + 1;

ALTER TABLE qa.trou_millesime
  ADD COLUMN nature text
  GENERATED ALWAYS AS (
    CASE WHEN retablissement_le IS NOT NULL THEN 'retablissement_reel'
         ELSE 'defaut_source' END
  ) STORED;

ALTER TABLE qa.trou_millesime ADD PRIMARY KEY (code_insee, rang_avant);
CREATE INDEX ON qa.trou_millesime (nature);

-- --- 2. Présence consolidée -------------------------------------------------
-- On comble uniquement les trous de nature 'defaut_source'.
DROP TABLE IF EXISTS cad.presence;
CREATE TABLE cad.presence (
  code_insee text NOT NULL,
  millesime  date NOT NULL,
  origine    text NOT NULL CHECK (origine IN ('observee','comblee')),
  PRIMARY KEY (code_insee, millesime)
);

INSERT INTO cad.presence (code_insee, millesime, origine)
SELECT code_insee, millesime, 'observee' FROM cad.observation;

INSERT INTO cad.presence (code_insee, millesime, origine)
SELECT t.code_insee, m.millesime, 'comblee'
FROM qa.trou_millesime t
JOIN cad.millesime m
  ON m.rang > t.rang_avant AND m.rang < t.rang_apres
WHERE t.nature = 'defaut_source'
ON CONFLICT (code_insee, millesime) DO NOTHING;

CREATE INDEX ON cad.presence (code_insee, millesime);
CREATE INDEX ON cad.presence (millesime) WHERE origine = 'comblee';
ANALYZE cad.presence;

-- --- 3. Journal d'anomalies -------------------------------------------------
-- Chaque trou comblé reste tracé : on n'efface pas un défaut, on le documente.
DROP TABLE IF EXISTS qa.anomalie;
CREATE TABLE qa.anomalie (
  id           bigserial PRIMARY KEY,
  regle        text NOT NULL,
  niveau       text NOT NULL CHECK (niveau IN ('info','anomalie','bloquant')),
  code_insee   text,
  millesime    date,
  detail       jsonb,
  detecte_le   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON qa.anomalie (regle);
CREATE INDEX ON qa.anomalie (code_insee);

INSERT INTO qa.anomalie (regle, niveau, code_insee, millesime, detail)
SELECT
  'R-SRC-001',
  -- Un trou d'un seul millésime est du bruit de publication banal ; au-delà d'un
  -- an (4 millésimes trimestriels) c'est probablement un retrait/refonte du levé
  -- cadastral, qui mérite un vrai regard plus tard.
  CASE WHEN t.millesimes_manquants >= 4 THEN 'anomalie' ELSE 'info' END,
  t.code_insee,
  t.vu_avant,
  jsonb_build_object(
    'libelle',              'code absent de millésimes intermédiaires puis revenu — comblé',
    'vu_avant',             t.vu_avant,
    'vu_apres',             t.vu_apres,
    'millesimes_manquants', t.millesimes_manquants
  )
FROM qa.trou_millesime t WHERE t.nature = 'defaut_source';

INSERT INTO qa.anomalie (regle, niveau, code_insee, millesime, detail)
SELECT
  'R-TMP-002', 'info', t.code_insee, t.vu_avant,
  jsonb_build_object(
    'libelle',              'absence expliquée par un rétablissement INSEE — NON comblée',
    'vu_avant',             t.vu_avant,
    'vu_apres',             t.vu_apres,
    'millesimes_manquants', t.millesimes_manquants,
    'retablissement_le',    t.retablissement_le
  )
FROM qa.trou_millesime t WHERE t.nature = 'retablissement_reel';
