-- =============================================================================
-- 005 — Référentiel administratif INSEE : départements et régions
-- =============================================================================
-- Sans ces deux tables, on ne dispose que des CODES de département portés par
-- les codes communes. Or l'interface s'adresse au grand public : « Haute-Savoie »
-- et « Auvergne-Rhône-Alpes » sont lisibles, « 74 » et « 84 » ne le sont pas.
--
-- Fichiers du Code officiel géographique au 1er janvier 2026, déposés dans /work :
--   v_departement_2026.csv  (101 lignes)
--   v_region_2026.csv       (18 lignes)
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS insee;

CREATE TABLE IF NOT EXISTS insee.departement (
  dep      text PRIMARY KEY,
  reg      text,
  cheflieu text,   -- code commune du chef-lieu
  tncc     text,   -- type de nom en clair : porte l'article (« le », « la », « les »)
  ncc      text,   -- nom en clair, majuscules non accentuées
  nccenr   text,   -- nom en clair enrichi, accentué
  libelle  text    -- libellé d'usage, article compris
);

CREATE TABLE IF NOT EXISTS insee.region (
  reg      text PRIMARY KEY,
  cheflieu text,
  tncc     text,
  ncc      text,
  nccenr   text,
  libelle  text
);

-- Le chargement lui-même se fait par \copy côté psql (voir le step 02-referentiel),
-- car COPY depuis le serveur exige que le fichier soit visible du container.
