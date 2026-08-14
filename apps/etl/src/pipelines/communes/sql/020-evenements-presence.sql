-- =============================================================================
-- 020 — Événements de présence, dérivés de la présence CONSOLIDÉE
-- =============================================================================
-- Rejoue la détection apparition / disparition / réapparition sur cad.presence
-- (trous de source comblés) au lieu de cad.observation (données brutes).
-- Effet attendu : les faux couples disparition+réapparition induits par les
-- défauts de publication disparaissent, sans toucher aux vrais rétablissements.
-- =============================================================================

DROP TABLE IF EXISTS cad.evenement_presence;
CREATE TABLE cad.evenement_presence AS
WITH pres AS (
  SELECT p.code_insee, m.rang, m.millesime
  FROM cad.presence p JOIN cad.millesime m USING (millesime)
),
bornes AS (
  SELECT code_insee, rang, millesime,
         lag(rang)  OVER (PARTITION BY code_insee ORDER BY rang) AS rang_prec,
         lead(rang) OVER (PARTITION BY code_insee ORDER BY rang) AS rang_suiv
  FROM pres
),
dernier AS (SELECT max(rang) AS rang_max FROM cad.millesime),
premier AS (SELECT min(rang) AS rang_min FROM cad.millesime)
SELECT
  b.code_insee,
  b.millesime,
  CASE
    WHEN b.rang_prec IS NULL AND b.rang = (SELECT rang_min FROM premier) THEN 'presente_a_l_origine'
    WHEN b.rang_prec IS NULL                                            THEN 'apparition'
    WHEN b.rang_prec <> b.rang - 1                                      THEN 'reapparition'
  END AS evenement_debut,
  CASE
    WHEN b.rang_suiv IS NULL AND b.rang <> (SELECT rang_max FROM dernier) THEN 'disparition'
    WHEN b.rang_suiv IS NOT NULL AND b.rang_suiv <> b.rang + 1            THEN 'interruption'
  END AS evenement_fin
FROM bornes b
WHERE b.rang_prec IS NULL OR b.rang_prec <> b.rang - 1
   OR b.rang_suiv IS NULL OR b.rang_suiv <> b.rang + 1;

CREATE INDEX ON cad.evenement_presence (code_insee);
CREATE INDEX ON cad.evenement_presence (evenement_debut);
CREATE INDEX ON cad.evenement_presence (evenement_fin);
ANALYZE cad.evenement_presence;
