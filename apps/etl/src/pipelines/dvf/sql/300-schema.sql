-- =============================================================================
-- nexus-analytics — modèle « historique des mutations » (DVF)
-- =============================================================================
-- DVF n'est pas un jeu de données, c'est une SUITE de livraisons. La DGFiP
-- publie deux fois par an une fenêtre glissante de cinq ans :
--
--   201904  2014 … 2018        202110  2016-s2 … 2021-s1
--   201910  2014 … 2019        202204  2017 … 2021
--   202004  2015 … 2019        202304  2018 … 2022
--   202010  2015-s2 … 2020     202404  2019 … 2023
--   202104  2016 … 2020        202410  2019-s2 … 2024-s1
--                              202504  2020 … 2024
--
-- Une même année est donc livrée jusqu'à six fois — et elle CHANGE d'une
-- livraison à l'autre. Mesuré sur le seul département 01 : entre avril et
-- octobre 2019, 2017 passe de 35 915 à 35 961 lignes. Les actes sont enregistrés
-- avec retard, corrigés, parfois retirés.
--
-- Deux conséquences dictent tout ce modèle.
--
-- 1. On historise. Garder la seule dernière livraison, c'est perdre le fait
--    qu'une vente a été déclarée puis retirée — information qui n'existe nulle
--    part ailleurs. Comme pour les parcelles, on stocke des CHANGEMENTS et non
--    des états : une ligne stable sur six livraisons pèse une ligne.
--
-- 2. L'absence n'est pas une suppression. Quand 2014 sort de la fenêtre en 2020,
--    elle disparaît des livraisons sans que rien n'ait été retiré. Une ligne
--    n'est donc évaluable que dans les livraisons qui COUVRENT sa date — d'où
--    dvf.publication.debut / .fin, qui bornent ce qu'une livraison peut infirmer.
--
-- Enfin, le champ qui identifierait l'acte (« Reference document ») est blanchi
-- dans l'open data. La mutation doit être reconstruite ; voir 310-distiller.sql.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS dvf;
CREATE SCHEMA IF NOT EXISTS raw;

-- --------------------------------------------------------------------------
-- Les livraisons effectivement chargées. Ancre chronologique et idempotence.
--
-- debut / fin ne sont pas déduits du nom des fichiers mais MESURÉS sur les
-- dates de mutation réellement présentes. Les noms mentent : « 2015-s2 » ne dit
-- pas si la coupure est au 30 juin ou au 1er juillet, et rien ne garantit que la
-- DGFiP s'y tienne. Ce qui borne une livraison, c'est son contenu.
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dvf.publication (
  publication  date    NOT NULL PRIMARY KEY,   -- 2019-04-01, 2019-10-01, …
  debut        date    NOT NULL,               -- première date de mutation couverte
  fin          date    NOT NULL,               -- dernière
  n_fichiers   integer NOT NULL,
  n_lignes     bigint  NOT NULL,
  n_ouvertures bigint,                         -- lignes apparues à cette livraison
  n_fermetures bigint,                         -- lignes retirées à cette livraison
  charge_le    timestamptz NOT NULL DEFAULT now(),
  duree_ms     integer
);

-- --------------------------------------------------------------------------
-- La ligne DVF, historisée.
--
-- Une ligne DVF n'a pas d'identifiant, et deux lignes rigoureusement identiques
-- sont légitimes (deux dépendances semblables dans la même vente). L'identité est
-- donc l'EMPREINTE DU CONTENU, plus un rang d'occurrence qui départage les
-- doublons exacts.
--
-- L'égalité stricte est ici légitime, alors qu'elle ne l'était pas pour les
-- géométries : ce sont des valeurs textuelles exactes recopiées d'un acte, sans
-- le bruit de recalcul en virgule flottante qui produisait 98 % de fausses
-- modifications sur les parcelles.
--
-- `ancre` est volontairement plus grossière que `empreinte` : elle survit à la
-- correction d'un prix ou d'une surface. C'est elle qui permet de distinguer
-- « la vente a été corrigée » de « une vente a disparu, une autre est apparue ».
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dvf.ligne (
  empreinte     bytea    NOT NULL,   -- sha1 du contenu normalisé de la ligne
  occurrence    smallint NOT NULL,   -- 1, 2, … pour les doublons exacts
  ancre         bytea    NOT NULL,   -- sha1(date, parcelle, disposition, type de local)

  vu_debut      date     NOT NULL,   -- première livraison où la ligne figure
  vu_fin        date,                -- première livraison COUVRANTE où elle manque
                                     -- NULL = toujours présente au dernier état

  -- La mutation reconstruite. Calculée à la DISTILLATION et non après coup :
  -- elle repose sur la contiguïté des lignes dans le fichier source, et cet
  -- ordre n'existe plus une fois les lignes rangées ici.
  --
  -- Volontairement dérivé du contenu, jamais d'un compteur. L'`id_mutation`
  -- d'Etalab (« 2021-1000 ») est un rang séquentiel national : il se décale à
  -- chaque republication dès qu'une ligne bouge n'importe où en France, et ne
  -- peut donc pas servir de clé à un historique.
  --
  -- Il n'entre PAS dans l'empreinte : si une mutation gagne une parcelle de
  -- numéro plus petit, son identifiant change sans que ses autres lignes aient
  -- bougé. Il est donc rafraîchi en place, comme les dates déclarées des
  -- parcelles — sans quoi une correction ferait rouvrir des lignes intactes.
  id_mutation   text     NOT NULL,

  date_mutation date     NOT NULL,
  nature        text     NOT NULL,   -- Vente, Adjudication, Échange, …
  valeur        numeric,             -- valeur foncière de la MUTATION, pas de la ligne
  disposition   text,

  -- Le rattachement au cadastre. Reconstruit selon la même composition que
  -- l'identifiant des parcelles (14 caractères), ce qui rend la jointure directe.
  id_parcelle   text     NOT NULL,
  commune       text     NOT NULL,

  type_local    text,
  surface_bati  numeric,
  nb_pieces     smallint,
  nb_lots       smallint,
  lot1          text,
  carrez1       numeric,
  volume        text,
  culture       text,
  culture_speciale text,
  surface_terrain numeric,

  PRIMARY KEY (empreinte, occurrence, vu_debut)
);

-- Rejouable sur une base déjà créée : CREATE TABLE IF NOT EXISTS n'ajoute rien
-- à une table existante.
ALTER TABLE dvf.ligne ADD COLUMN IF NOT EXISTS id_mutation text;

CREATE INDEX IF NOT EXISTS ligne_mutation    ON dvf.ligne (id_mutation);
CREATE INDEX IF NOT EXISTS ligne_parcelle    ON dvf.ligne (id_parcelle);
CREATE INDEX IF NOT EXISTS ligne_commune_date ON dvf.ligne (commune, date_mutation);
CREATE INDEX IF NOT EXISTS ligne_ancre       ON dvf.ligne (ancre);
CREATE INDEX IF NOT EXISTS ligne_ouverte     ON dvf.ligne (date_mutation) WHERE vu_fin IS NULL;

-- --------------------------------------------------------------------------
-- Table de préparation, copiée par livraison (CREATE TABLE … LIKE) pour que
-- plusieurs livraisons puissent être chargées de front sans se marcher dessus.
-- Tout est en texte : le fichier source est en JJ/MM/AAAA et virgule décimale,
-- et une seule ligne mal formée ferait échouer un COPY typé sur des millions.
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS raw.dvf_stage (
  ordre            bigint,   -- rang dans le fichier : PORTE l'information de
                             -- regroupement en mutations, ne jamais le perdre
  service          text, ref_doc text,
  cgi1 text, cgi2 text, cgi3 text, cgi4 text, cgi5 text,
  no_disposition   text, date_mutation text, nature_mutation text, valeur_fonciere text,
  no_voie text, btq text, type_voie text, code_voie text, voie text,
  code_postal text, nom_commune text, code_departement text, code_commune text,
  prefixe text, section text, no_plan text, no_volume text,
  lot1 text, carrez1 text, lot2 text, carrez2 text, lot3 text, carrez3 text,
  lot4 text, carrez4 text, lot5 text, carrez5 text, nb_lots text,
  code_type_local text, type_local text, id_local text,
  surface_bati text, nb_pieces text,
  nature_culture text, nature_culture_speciale text, surface_terrain text
);

-- --------------------------------------------------------------------------
-- Identifiant de parcelle à 14 caractères, reconstruit depuis les colonnes
-- éclatées du fichier brut. Même composition que parc.version.id_parcelle :
-- c'est ce qui rend DVF et cadastre joignables sans table de correspondance.
--
-- Le code département fait 2 caractères en métropole et 3 outre-mer, et le code
-- commune complète toujours à 5. Section et numéro de plan sont livrés sans
-- zéros de tête et doivent être recomposés.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dvf.id_parcelle(
  p_dep text, p_com text, p_prefixe text, p_section text, p_plan text
) RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE WHEN p_dep IS NULL OR p_com IS NULL OR p_section IS NULL OR p_plan IS NULL
              THEN NULL
              ELSE lpad(p_dep || lpad(p_com, 3, '0'), 5, '0')
                || lpad(coalesce(nullif(p_prefixe, ''), '000'), 3, '0')
                || lpad(p_section, 2, '0')
                || lpad(p_plan, 4, '0')
         END;
$$;

-- --------------------------------------------------------------------------
-- Nombre décimal à la française : « 165000,00 » → 165000.00.
-- Renvoie NULL plutôt que d'échouer : DVF contient des champs vides et, plus
-- rarement, des valeurs aberrantes qu'il vaut mieux perdre que voir interrompre
-- le chargement d'une livraison entière.
-- --------------------------------------------------------------------------
-- --------------------------------------------------------------------------
-- Conversions tolérantes, SANS bloc EXCEPTION.
--
-- La première version encadrait `to_date` et le cast numérique par
-- `EXCEPTION WHEN others THEN RETURN NULL`. C'est le réflexe naturel, et c'est
-- un piège à cette échelle : en PL/pgSQL, **tout bloc EXCEPTION ouvre une
-- sous-transaction à chaque appel**. Sur les 18 928 987 lignes d'une livraison
-- nationale, Postgres a fini par céder — « AbortSubTransaction while in COMMIT
-- state » — et le `WHEN others` a avalé l'erreur d'infrastructure en la
-- déguisant en valeur illisible.
--
-- La signature du défaut est qu'il n'était pas déterministe : la même livraison
-- a rendu 395 974 puis 353 703 « dates illisibles », alors que le fichier n'en
-- contient aucune. Un `WHEN others` ne distingue pas une donnée fautive d'une
-- machine à bout de souffle, et transforme la seconde en la première.
--
-- On valide donc AVANT de convertir, en SQL pur : pas de sous-transaction, et
-- au passage bien plus rapide. `pg_input_is_valid` (PostgreSQL 16+) est fait
-- exactement pour ça.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dvf.date_fr(p text)
RETURNS date LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  -- On recompose en ISO plutôt que d'appeler to_date : `to_date` est indulgent
  -- et ferait glisser un 31 février au 3 mars, ce qui inventerait une date que
  -- la source ne porte pas. Le cast ISO, lui, refuse — et on rend NULL.
  SELECT CASE
    WHEN btrim(p) ~ '^[0-9]{2}/[0-9]{2}/[0-9]{4}$'
     AND pg_input_is_valid(substr(btrim(p), 7, 4) || '-' || substr(btrim(p), 4, 2)
                            || '-' || substr(btrim(p), 1, 2), 'date')
    THEN (substr(btrim(p), 7, 4) || '-' || substr(btrim(p), 4, 2)
           || '-' || substr(btrim(p), 1, 2))::date
  END;
$$;

CREATE OR REPLACE FUNCTION dvf.nombre(p text)
RETURNS numeric LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE
    WHEN pg_input_is_valid(replace(nullif(btrim(p), ''), ',', '.'), 'numeric')
    THEN replace(btrim(p), ',', '.')::numeric
  END;
$$;

