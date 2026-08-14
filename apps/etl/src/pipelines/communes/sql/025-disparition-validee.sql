-- =============================================================================
-- 025 — Confrontation des disparitions cadastrales au registre INSEE
-- =============================================================================
-- Pour chaque code qui cesse d'apparaître dans les millésimes, on cherche le
-- mouvement INSEE qui l'explique, et on mesure l'écart entre la date d'effet
-- légale et la dernière observation cadastrale.
--
-- CORRECTION IMPORTANTE par rapport à une première version : il faut rapprocher
-- le mouvement le PLUS PROCHE de la disparition, pas le premier de l'histoire du
-- code. Avec un min(date_eff), sept disparitions affichaient un écart de 13 000 à
-- 17 000 jours : leur code portait une fusion-association des années 1970
-- (MOD 33) et la requête attrapait cet événement de 1973 au lieu du mouvement
-- contemporain. Le même piège fait passer un rétablissement de 1983 pour
-- l'explication d'une absence de 2021.
-- =============================================================================

DROP TABLE IF EXISTS cad.disparition_validee;
CREATE TABLE cad.disparition_validee AS
SELECT
  e.code_insee,
  e.millesime AS dernier_millesime,
  m.date_eff  AS insee_date_eff,
  m.mods      AS insee_mods,
  m.successeurs AS insee_successeurs,
  (e.millesime - m.date_eff) AS ecart_jours
FROM cad.evenement_presence e
LEFT JOIN LATERAL (
  -- Le mouvement dont la date d'effet est la plus proche de la dernière
  -- observation, dans une fenêtre de +/- 3 ans. Au-delà, on considère qu'il n'y
  -- a pas de lien de causalité plausible.
  SELECT v.date_eff,
         string_agg(DISTINCT v.mod, ',' ORDER BY v.mod)     AS mods,
         string_agg(DISTINCT v.com_ap, ',' ORDER BY v.com_ap) AS successeurs
  FROM insee.mvt_commune v
  WHERE v.com_av = e.code_insee
    AND v.typecom_av = 'COM'
    AND v.com_ap <> e.code_insee
    AND v.date_eff BETWEEN e.millesime - INTERVAL '3 years'
                       AND e.millesime + INTERVAL '3 years'
  GROUP BY v.date_eff
  ORDER BY abs(e.millesime - v.date_eff)
  LIMIT 1
) m ON true
WHERE e.evenement_fin = 'disparition';

ALTER TABLE cad.disparition_validee ADD PRIMARY KEY (code_insee, dernier_millesime);
CREATE INDEX ON cad.disparition_validee (insee_date_eff);

-- Trace les disparitions qu'aucun mouvement INSEE n'explique : ce sont les seules
-- qui méritent un examen humain.
INSERT INTO qa.anomalie (regle, niveau, code_insee, millesime, detail)
SELECT 'R-TMP-003', 'anomalie', d.code_insee, d.dernier_millesime,
       jsonb_build_object(
         'libelle', 'disparition cadastrale sans mouvement INSEE correspondant à +/- 3 ans')
FROM cad.disparition_validee d
WHERE d.insee_date_eff IS NULL;
