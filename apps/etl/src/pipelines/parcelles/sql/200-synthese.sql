-- =============================================================================
-- nexus-analytics — synthèse et événements par parcelle
-- =============================================================================
-- parc.version est un journal : optimisé pour l'écriture incrémentale, pénible à
-- interroger. On en dérive ici les deux objets que le site consomme réellement :
--
--   parc.parcelle   une ligne par parcelle jamais observée — sa fiche d'identité.
--   parc.evenement  la chronologie de sa vie, un fait par ligne.
--
-- Entièrement reconstruit à chaque appel : ce sont des vues matérialisées à la
-- main, jamais une source de vérité.
-- =============================================================================

-- Cadrage mémoire, à l'échelle nationale indispensable.
--
-- À 101 M de versions, les regroupements et les constructions d'index de ce
-- script lancent des workers parallèles qui allouent leurs tables de hachage en
-- MÉMOIRE PARTAGÉE. C'est ce qui a saturé /dev/shm (1 Go dans le conteneur) et
-- fait échouer le département 12 pendant l'ingestion. Le distillateur avait été
-- corrigé, pas la synthèse — qui n'avait jamais tourné qu'à l'échelle d'un
-- département.
--
-- SET LOCAL et non SET : ces scripts sont envoyés d'un bloc, donc dans une
-- transaction implicite, et le réglage ne fuit pas vers les autres emprunteurs
-- du pool.
SET LOCAL work_mem = '128MB';
SET LOCAL max_parallel_workers_per_gather = 1;
SET LOCAL enable_parallel_hash = off;

-- --------------------------------------------------------------------------
-- Les relevés d'un département, numérotés. Sert à répondre à « quel relevé vient
-- après celui-ci ? », question omniprésente ici : une disparition n'est pas
-- constatée au dernier relevé où la parcelle était là, mais au suivant.
-- --------------------------------------------------------------------------
CREATE OR REPLACE VIEW parc.releve AS
SELECT departement,
       millesime,
       row_number() OVER (PARTITION BY departement ORDER BY millesime) AS rang,
       lead(millesime)  OVER (PARTITION BY departement ORDER BY millesime) AS suivant,
       lag(millesime)   OVER (PARTITION BY departement ORDER BY millesime) AS precedent
  FROM parc.millesime;

-- --------------------------------------------------------------------------
-- Fiche d'identité d'une parcelle.
-- --------------------------------------------------------------------------
DROP TABLE IF EXISTS parc.parcelle;
CREATE TABLE parc.parcelle AS
WITH bornes AS (
  SELECT departement, min(millesime) AS premier, max(millesime) AS dernier
    FROM parc.millesime GROUP BY departement
),
agg AS (
  SELECT v.id_parcelle,
         min(v.commune)  AS commune,
         min(v.prefixe)  AS prefixe,
         min(v.section)  AS section,
         min(v.numero)   AS numero,
         count(*)::int   AS n_versions,
         min(v.vu_debut) AS vu_premier,
         max(v.vu_debut) AS vu_dernier_debut,
         -- Encore ouverte au dernier relevé ?
         bool_or(v.vu_fin IS NULL) AS presente,
         max(v.vu_fin)   AS vu_dernier_fin,
         min(v.cree_source) AS cree_source,
         max(v.maj_source)  AS maj_source
    FROM parc.version v
   GROUP BY v.id_parcelle
)
SELECT a.id_parcelle,
       a.commune, a.prefixe, a.section, a.numero,
       a.n_versions,
       a.vu_premier,
       -- Dernier relevé où la parcelle a été vue, quelle que soit sa version.
       CASE WHEN a.presente THEN b.dernier ELSE a.vu_dernier_fin END AS vu_dernier,
       a.presente,
       -- Une parcelle vue dès le premier relevé existait déjà avant : on ne
       -- connaît pas sa date d'apparition, seulement qu'elle est antérieure.
       (a.vu_premier > b.premier) AS apparition_observee,
       a.cree_source,
       a.maj_source,
       -- Écart entre ce que la source déclare et ce qu'on a pu observer. Une
       -- parcelle créée en 2008 et vue pour la première fois en 2018 n'est pas
       -- une nouveauté de 2018 — c'est notre fenêtre qui commence là.
       (a.cree_source < b.premier) AS anterieure_a_nos_releves
  FROM agg a
  -- Jointure d'ÉGALITÉ sur le département, et non un LIKE. À l'échelle
  -- nationale, `commune LIKE b.departement || '%'` interdit toute jointure par
  -- hachage : Postgres croiserait 100 M de parcelles avec les 101 bornes ligne à
  -- ligne. parc.departement_de rend la clé calculable, donc joignable.
  JOIN bornes b ON b.departement = parc.departement_de(a.commune);

ALTER TABLE parc.parcelle ADD PRIMARY KEY (id_parcelle);
CREATE INDEX ON parc.parcelle (commune);
CREATE INDEX ON parc.parcelle (commune, prefixe, section);
CREATE INDEX ON parc.parcelle (presente) WHERE NOT presente;

-- --------------------------------------------------------------------------
-- La vie d'une parcelle, un fait par ligne.
--
-- `millesime` est toujours le relevé où le fait est CONSTATÉ, pas celui où il
-- s'est produit dans le monde réel. C'est la même prudence que pour les
-- communes : on date ce qu'on observe, l'écart avec la réalité juridique est
-- une donnée en soi, pas quelque chose à masquer.
-- --------------------------------------------------------------------------
DROP TABLE IF EXISTS parc.evenement;
CREATE TABLE parc.evenement (
  id_parcelle text     NOT NULL,
  millesime   date     NOT NULL,
  type        text     NOT NULL,
  detail      text[],
  no_version  smallint
);

-- Apparitions : première version d'une parcelle absente du relevé précédent.
INSERT INTO parc.evenement (id_parcelle, millesime, type, no_version)
SELECT p.id_parcelle, p.vu_premier, 'apparition', 1
  FROM parc.parcelle p
 WHERE p.apparition_observee;

-- Modifications : chaque nouvelle version qui succède à une précédente.
INSERT INTO parc.evenement (id_parcelle, millesime, type, detail, no_version)
SELECT v.id_parcelle, v.vu_debut, 'modification',
       array_remove(ARRAY[
         -- Pas de 'dates_source' ici : les dates déclarées par la source
         -- n'ouvrent pas de version (voir 110-distiller.sql), elles sont mises à
         -- jour en place. Une modification porte donc toujours sur le terrain.
         CASE WHEN v.sha         <>            p.sha           THEN 'geometrie'  END,
         CASE WHEN v.contenance  IS DISTINCT FROM p.contenance THEN 'contenance' END,
         CASE WHEN v.arpente     IS DISTINCT FROM p.arpente    THEN 'arpente'    END
       ], NULL),
       v.no_version
  FROM parc.version v
  JOIN parc.version p ON p.id_parcelle = v.id_parcelle AND p.no_version = v.no_version - 1;

-- Disparitions : dernière version close, constatée au relevé SUIVANT.
INSERT INTO parc.evenement (id_parcelle, millesime, type, no_version)
SELECT v.id_parcelle, r.suivant, 'disparition', v.no_version
  FROM parc.version v
  JOIN parc.parcelle p ON p.id_parcelle = v.id_parcelle AND NOT p.presente
                      AND p.vu_dernier = v.vu_fin
  -- Égalité et non LIKE : à 100 M de versions, un LIKE contre les 101 lignes de
  -- parc.releve se réévalue pour chaque parcelle au lieu de se résoudre par
  -- hachage.
  JOIN parc.releve r ON r.millesime = v.vu_fin
                    AND r.departement = parc.departement_de(v.commune)
 WHERE v.vu_fin IS NOT NULL AND r.suivant IS NOT NULL;

-- Réapparitions : la parcelle revient après avoir été absente d'au moins un
-- relevé. Pour les communes, ces trous se sont révélés être des bugs de source
-- dans 94 cas sur 95. On ne présume rien ici : on les compte et on les expose.
INSERT INTO parc.evenement (id_parcelle, millesime, type, no_version)
SELECT v.id_parcelle, v.vu_debut, 'reapparition', v.no_version
  FROM parc.version v
  JOIN parc.version p ON p.id_parcelle = v.id_parcelle AND p.no_version = v.no_version - 1
  JOIN parc.releve r  ON r.millesime = p.vu_fin
                     AND r.departement = parc.departement_de(v.commune)
 WHERE p.vu_fin IS NOT NULL AND r.suivant IS DISTINCT FROM v.vu_debut;

CREATE INDEX ON parc.evenement (id_parcelle, millesime);
CREATE INDEX ON parc.evenement (millesime, type);

ANALYZE parc.parcelle;
ANALYZE parc.evenement;
