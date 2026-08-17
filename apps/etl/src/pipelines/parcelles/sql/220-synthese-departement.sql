-- =============================================================================
-- nexus-analytics — synthèse d'UN SEUL département
-- =============================================================================
-- 200-synthese.sql reconstruit la couche dérivée en entier : DROP puis CREATE
-- TABLE AS sur parc.parcelle, parc.evenement et parc.filiation. C'est le bon
-- comportement pour une reconstruction de bout en bout, et le mauvais dès qu'on
-- veut simplement rendre exploitable un département fraîchement ingéré :
-- rejouer le national sur 67 M de versions pour en ajouter 2 M coûte des heures
-- et entre en concurrence avec l'ingestion qui tourne encore.
--
-- Cette fonction fait le même travail, borné à un département, en remplaçant
-- ses lignes plutôt qu'en refondant les tables. Le résultat est identique à ce
-- que produirait 200-synthese.sql pour ce département — les définitions sont
-- reprises telles quelles, y compris les jointures d'égalité sur
-- parc.departement_de qui remplacent les LIKE pour rester joignables par hachage.
--
-- Prérequis : les tables existent déjà (200-synthese.sql au moins une fois).
-- =============================================================================

CREATE OR REPLACE FUNCTION parc.synthetiser_departement(p_dep text)
RETURNS TABLE (n_parcelles bigint, n_evenements bigint, n_filiations bigint)
LANGUAGE plpgsql AS $$
DECLARE
  v_premier date;
  v_dernier date;
BEGIN
  SET LOCAL work_mem = '64MB';
  SET LOCAL max_parallel_workers_per_gather = 1;
  SET LOCAL enable_parallel_hash = off;

  IF to_regclass('parc.parcelle') IS NULL OR to_regclass('parc.filiation') IS NULL THEN
    RAISE EXCEPTION 'couche dérivée absente : lancer parcelles:synthese une première fois';
  END IF;

  SELECT min(millesime), max(millesime) INTO v_premier, v_dernier
    FROM parc.millesime WHERE departement = p_dep;

  IF v_premier IS NULL THEN
    RAISE EXCEPTION 'aucun relevé distillé pour le département %', p_dep;
  END IF;

  -- --- Fiches d'identité --------------------------------------------------
  DELETE FROM parc.parcelle WHERE parc.departement_de(commune) = p_dep;

  INSERT INTO parc.parcelle (
    id_parcelle, commune, prefixe, section, numero, n_versions, vu_premier,
    vu_dernier, presente, apparition_observee, cree_source, maj_source,
    anterieure_a_nos_releves)
  SELECT a.id_parcelle, a.commune, a.prefixe, a.section, a.numero, a.n_versions,
         a.vu_premier,
         CASE WHEN a.presente THEN v_dernier ELSE a.vu_dernier_fin END,
         a.presente,
         (a.vu_premier > v_premier),
         a.cree_source, a.maj_source,
         (a.cree_source < v_premier)
    FROM (SELECT v.id_parcelle,
                 min(v.commune) AS commune, min(v.prefixe) AS prefixe,
                 min(v.section) AS section, min(v.numero)  AS numero,
                 count(*)::int  AS n_versions,
                 min(v.vu_debut) AS vu_premier,
                 bool_or(v.vu_fin IS NULL) AS presente,
                 max(v.vu_fin)   AS vu_dernier_fin,
                 min(v.cree_source) AS cree_source,
                 max(v.maj_source)  AS maj_source
            FROM parc.version v
           WHERE parc.departement_de(v.commune) = p_dep
           GROUP BY v.id_parcelle) a;

  -- --- Événements ---------------------------------------------------------
  -- Le filtre porte sur les 5 premiers caractères de l'identifiant, qui SONT
  -- le code commune : parc.evenement ne porte pas de colonne département, et
  -- une jointure sur parc.parcelle pour le retrouver coûterait plus cher que
  -- de le relire là où il est déjà.
  DELETE FROM parc.evenement WHERE parc.departement_de(substring(id_parcelle, 1, 5)) = p_dep;

  INSERT INTO parc.evenement (id_parcelle, millesime, type, no_version)
  SELECT p.id_parcelle, p.vu_premier, 'apparition', 1
    FROM parc.parcelle p
   WHERE parc.departement_de(p.commune) = p_dep AND p.apparition_observee;

  INSERT INTO parc.evenement (id_parcelle, millesime, type, detail, no_version)
  SELECT v.id_parcelle, v.vu_debut, 'modification',
         array_remove(ARRAY[
           CASE WHEN v.sha        <>            p.sha        THEN 'geometrie'  END,
           CASE WHEN v.contenance IS DISTINCT FROM p.contenance THEN 'contenance' END,
           CASE WHEN v.arpente    IS DISTINCT FROM p.arpente    THEN 'arpente'    END
         ], NULL),
         v.no_version
    FROM parc.version v
    JOIN parc.version p ON p.id_parcelle = v.id_parcelle AND p.no_version = v.no_version - 1
   WHERE parc.departement_de(v.commune) = p_dep;

  INSERT INTO parc.evenement (id_parcelle, millesime, type, no_version)
  SELECT v.id_parcelle, r.suivant, 'disparition', v.no_version
    FROM parc.version v
    JOIN parc.parcelle p ON p.id_parcelle = v.id_parcelle AND NOT p.presente
                        AND p.vu_dernier = v.vu_fin
    JOIN parc.releve r ON r.millesime = v.vu_fin AND r.departement = p_dep
   WHERE parc.departement_de(v.commune) = p_dep
     AND v.vu_fin IS NOT NULL AND r.suivant IS NOT NULL;

  INSERT INTO parc.evenement (id_parcelle, millesime, type, no_version)
  SELECT v.id_parcelle, v.vu_debut, 'reapparition', v.no_version
    FROM parc.version v
    JOIN parc.version p ON p.id_parcelle = v.id_parcelle AND p.no_version = v.no_version - 1
    JOIN parc.releve r  ON r.millesime = p.vu_fin AND r.departement = p_dep
   WHERE parc.departement_de(v.commune) = p_dep
     AND p.vu_fin IS NOT NULL AND r.suivant IS DISTINCT FROM v.vu_debut;

  -- --- Filiation ----------------------------------------------------------
  -- Une filiation ne franchit jamais une frontière départementale : le cadastre
  -- renumérote à l'intérieur d'un département, jamais de l'un à l'autre. On peut
  -- donc remplacer les liens de ce département sans toucher aux autres.
  DELETE FROM parc.filiation WHERE parc.departement_de(substring(id_avant, 1, 5)) = p_dep;

  CREATE TEMP TABLE _part ON COMMIT DROP AS
  SELECT e.millesime, e.id_parcelle AS id, v.sha, v.geom,
         ST_Area(ST_Transform(v.geom, parc.srid_metrique(p_dep))) AS aire
    FROM parc.evenement e
    JOIN parc.version   v ON v.id_parcelle = e.id_parcelle AND v.no_version = e.no_version
   WHERE e.type = 'disparition' AND parc.departement_de(v.commune) = p_dep;

  CREATE TEMP TABLE _arr ON COMMIT DROP AS
  SELECT e.millesime, e.id_parcelle AS id, v.sha, v.geom,
         ST_Area(ST_Transform(v.geom, parc.srid_metrique(p_dep))) AS aire
    FROM parc.evenement e
    JOIN parc.version   v ON v.id_parcelle = e.id_parcelle AND v.no_version = e.no_version
   WHERE e.type = 'apparition' AND parc.departement_de(v.commune) = p_dep;

  CREATE INDEX ON _part USING GIST (geom);
  CREATE INDEX ON _arr  USING GIST (geom);
  CREATE INDEX ON _part (millesime);
  CREATE INDEX ON _arr  (millesime);
  ANALYZE _part; ANALYZE _arr;

  INSERT INTO parc.filiation (millesime, id_avant, id_apres, type,
                              part_avant, part_apres, certain)
  WITH croisement AS (
    SELECT d.millesime, d.id AS id_avant, a.id AS id_apres,
           (d.sha = a.sha) AS meme_empreinte, d.aire AS aire_avant, a.aire AS aire_apres,
           ST_Area(ST_Transform(ST_Intersection(ST_MakeValid(d.geom), ST_MakeValid(a.geom)),
                                parc.srid_metrique(p_dep))) AS aire_commune
      FROM _part d
      JOIN _arr  a ON a.millesime = d.millesime
                  AND d.geom && a.geom AND ST_Intersects(d.geom, a.geom)),
  retenu AS (
    SELECT *, aire_commune / nullif(aire_avant, 0) AS part_avant,
              aire_commune / nullif(aire_apres, 0) AS part_apres
      FROM croisement
     WHERE aire_commune > 0
       AND (aire_commune / nullif(aire_avant, 0) > 0.05
         OR aire_commune / nullif(aire_apres, 0) > 0.05)),
  cardinal AS (
    SELECT r.*,
           count(*) OVER (PARTITION BY r.millesime, r.id_avant) AS n_successeurs,
           count(*) OVER (PARTITION BY r.millesime, r.id_apres) AS n_predecesseurs
      FROM retenu r)
  SELECT millesime, id_avant, id_apres,
         CASE WHEN meme_empreinte                            THEN 'renumerotation'
              WHEN n_successeurs > 1 AND n_predecesseurs = 1 THEN 'division'
              WHEN n_predecesseurs > 1 AND n_successeurs = 1 THEN 'reunion'
              ELSE 'redecoupage' END,
         part_avant, part_apres, meme_empreinte
    FROM cardinal;

  SELECT count(*) INTO n_parcelles FROM parc.parcelle
   WHERE parc.departement_de(commune) = p_dep;
  SELECT count(*) INTO n_evenements FROM parc.evenement
   WHERE parc.departement_de(substring(id_parcelle, 1, 5)) = p_dep;
  SELECT count(*) INTO n_filiations FROM parc.filiation
   WHERE parc.departement_de(substring(id_avant, 1, 5)) = p_dep;
  RETURN NEXT;
END;
$$;
