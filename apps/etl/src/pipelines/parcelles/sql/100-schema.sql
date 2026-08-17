-- =============================================================================
-- nexus-analytics — modèle « vie d'une parcelle »
-- =============================================================================
-- Le pipeline communes stockait UNE TABLE PAR MILLÉSIME (raw.communes_2026_06_01,
-- etc.). À 35 000 communes c'est sans conséquence : 558 Mo × 32 = 18 Go.
-- Pour les parcelles la même approche exploserait : 1,56 M de parcelles pour la
-- SEULE Moselle, soit ~50 M d'observations sur 32 relevés, et 95 départements
-- derrière. On change donc de stratégie.
--
-- Observation empirique qui rend tout le reste possible : d'un relevé à l'autre,
-- l'immense majorité des parcelles est rigoureusement identique. On ne stocke
-- donc pas des états, on stocke des CHANGEMENTS :
--
--   parc.version     une ligne = un état stable d'une parcelle sur une PLAGE de
--                    relevés, géométrie comprise. Une parcelle jamais modifiée
--                    depuis 2018 pèse UNE ligne et UNE géométrie, pas trente-deux.
--
-- C'est un SCD2 (slowly changing dimension) appliqué à de la géométrie.
--
-- Deux axes de temps, à ne jamais confondre :
--   - vu_debut / vu_fin       ce que NOUS avons observé, borné par nos relevés
--                             (2018-04-03 au plus tôt).
--   - cree_source/maj_source  ce que la SOURCE déclare. Ces dates remontent bien
--                             avant nos relevés (2008 et au-delà) : c'est la
--                             seule fenêtre sur l'histoire d'avant 2018.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS parc;
CREATE SCHEMA IF NOT EXISTS raw;

-- --------------------------------------------------------------------------
-- Les relevés effectivement distillés. Ancre chronologique et idempotence :
-- un millésime déjà présent ici est sauté par l'ingestion.
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS parc.millesime (
  departement    text    NOT NULL,
  millesime      date    NOT NULL,
  format         text    NOT NULL CHECK (format IN ('shp', 'geojson')),
  n_parcelles    integer NOT NULL,   -- lignes du relevé, après dédoublonnage
  n_ouvertures   integer,            -- versions créées à ce relevé
  n_fermetures   integer,            -- versions closes à ce relevé
  n_disparitions integer,            -- parcelles absentes du relevé
  n_doublons     integer,            -- identifiants livrés en double par la source
  distille_le    timestamptz NOT NULL DEFAULT now(),
  duree_ms       integer,

  -- Empreinte du fichier source AU MOMENT où on l'a distillé.
  --
  -- Sans elle, l'idempotence repose sur la seule date du relevé — et un millésime
  -- ancien REPUBLIÉ avec des données corrigées passerait inaperçu. Ce n'est pas
  -- une hypothèse d'école : au 15 août 2026, tous les millésimes de l'archive
  -- portaient une date de publication S3 de février-mars 2026. L'archive est
  -- réécrite, il faut pouvoir s'en apercevoir.
  etag           text,
  taille         bigint,
  publie_le      timestamptz,

  PRIMARY KEY (departement, millesime)
);

-- Colonnes ajoutées après coup : une base déjà initialisée doit les recevoir
-- sans être reconstruite.
ALTER TABLE parc.millesime ADD COLUMN IF NOT EXISTS etag      text;
ALTER TABLE parc.millesime ADD COLUMN IF NOT EXISTS taille    bigint;
ALTER TABLE parc.millesime ADD COLUMN IF NOT EXISTS publie_le timestamptz;

-- --------------------------------------------------------------------------
-- L'empreinte de contenu d'une géométrie.
--
-- L'empreinte est un SHA-1 de la géométrie normalisée et ramenée à la grille du
-- GeoJSON (7 décimales, ~1 cm). Elle est portée par parc.version.
--
-- CE QU'ELLE FAIT, ET CE QU'ELLE NE FAIT PAS. Elle sert à repérer une parcelle
-- renumérotée À L'INTÉRIEUR d'un même relevé — deux identifiants, un seul
-- dessin, cas typique d'une commune absorbée dont les parcelles changent de
-- préfixe. Là, les coordonnées sortent du même fichier et l'égalité stricte est
-- légitime.
--
-- Elle ne sert PAS à décider si une parcelle a changé d'un relevé à l'autre : la
-- source republie ses coordonnées avec un bruit centimétrique qui rend toute
-- égalité exacte inopérante. Cette comparaison-là est géométrique et tolérante,
-- voir l'en-tête de 110-distiller.sql.
--
-- POURQUOI PAS DE MAGASIN DE GÉOMÉTRIES SÉPARÉ. La première version de ce schéma
-- stockait les géométries dans une table à part, adressée par cette empreinte,
-- pour les mutualiser. L'idée ne tenait pas : le modèle de versions déduplique
-- DÉJÀ le cas qui compte — une parcelle inchangée depuis 2018 a une seule
-- version, donc une seule géométrie, pas trente-deux. Il ne restait à mutualiser
-- que deux parcelles distinctes au dessin identique, soit 1 cas sur 1 539 263 au
-- relevé de 2018. Pour ce gain nul, la table imposait une jointure de 1,5 M de
-- lignes sur une clé sans rapport avec l'identifiant de parcelle, donc un hachage
-- de 900 Mo en mémoire partagée à chaque relevé — ce qui a fini par saturer le
-- /dev/shm du conteneur. La géométrie vit maintenant dans la version, joignable
-- par la clé primaire.
--
-- Les deux traitements appliqués avant hachage restent nécessaires pour que
-- l'empreinte survive à la bascule de format de juillet 2022 :
--
--   ST_SnapToGrid — le shapefile porte des float64 bruts, le GeoJSON du texte
--     arrondi à 7 décimales. (SnapToGrid et pas ReducePrecision : on cherche une
--     représentation canonique des coordonnées, pas une géométrie valide à
--     précision réduite. C'est une opération de coordonnées, ~10× plus rapide,
--     sans effet de bord topologique. La géométrie hachée n'est jamais stockée,
--     seule l'originale l'est.)
--
--   ST_Normalize — le shapefile oriente ses anneaux extérieurs dans le sens
--     horaire, le GeoJSON (RFC 7946) dans le sens trigonométrique. Sans ordre
--     canonique, la même parcelle change d'empreinte en changeant de format.
--
-- SHA-1 plutôt que SHA-256 : 20 octets au lieu de 32, sur ~2 M de lignes ça
-- compte, et il n'y a ici aucun enjeu adversarial — on compare, on n'authentifie
-- pas.
-- --------------------------------------------------------------------------
DROP TABLE IF EXISTS parc.geometrie;

/** Géométrie hashable : même empreinte pour le shp de 2018 et le geojson de 2026. */
CREATE OR REPLACE FUNCTION parc.geom_canonique(g geometry)
RETURNS geometry
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  -- Une parcelle plus fine que la grille peut se réduire à rien en s'y accrochant.
  -- Dans ce cas on retombe sur la géométrie d'origine : mieux vaut une poignée de
  -- fausses modifications qu'une parcelle perdue.
  SELECT coalesce(
    nullif(ST_Normalize(ST_SnapToGrid(g, 1e-7)), 'MULTIPOLYGON EMPTY'::geometry),
    ST_Normalize(g)
  );
$$;

/** Empreinte de contenu d'une géométrie. */
CREATE OR REPLACE FUNCTION parc.sha_geom(g geometry)
RETURNS bytea
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT digest(ST_AsBinary(parc.geom_canonique(g)), 'sha1');
$$;

-- --------------------------------------------------------------------------
-- Une version = un état stable d'une parcelle sur [vu_debut, vu_fin].
--
-- vu_fin IS NULL  ⇔  la version est encore ouverte, c'est-à-dire observée au
-- dernier relevé distillé. C'est ce qui rend l'ingestion tenable : à chaque
-- millésime on n'écrit QUE les changements (quelques milliers de lignes), au
-- lieu de repousser une date de fin sur les 1,5 M de parcelles inchangées.
--
-- Quand vu_fin est renseignée, elle porte le DERNIER relevé où cet état a été
-- observé — pas la date de sa disparition.
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS parc.version (
  id_parcelle  text     NOT NULL,
  no_version   smallint NOT NULL,

  geom         geometry(MultiPolygon, 4326) NOT NULL,
  sha          bytea    NOT NULL,
  -- Calculée une fois pour toutes, en geography (juste aussi bien en métropole
  -- qu'outre-mer, là où un ST_Transform vers Lambert-93 serait faux).
  -- Sert à confronter la géométrie à la `contenance` déclarée par la source.
  surface_m2   double precision,

  -- Décomposition de l'identifiant, dénormalisée volontairement : toutes les
  -- requêtes du site filtrent là-dessus, et un split à la volée sur 2 M de
  -- lignes coûte plus cher que ces quelques octets.
  commune      text     NOT NULL,
  prefixe      text     NOT NULL,
  section      text     NOT NULL,
  numero       text     NOT NULL,

  contenance   integer,          -- m², déclarée par la source
  arpente      boolean,
  cree_source  date,             -- axe « temps source », antérieur à nos relevés
  maj_source   date,

  vu_debut     date     NOT NULL,
  vu_fin       date,             -- NULL = encore présente au dernier relevé

  PRIMARY KEY (id_parcelle, no_version)
);

-- Le cœur de la boucle d'ingestion : « l'état courant de toutes les parcelles »,
-- à confronter au relevé entrant.
CREATE INDEX IF NOT EXISTS version_ouverte_idx ON parc.version (id_parcelle)
  WHERE vu_fin IS NULL;
CREATE INDEX IF NOT EXISTS version_commune_idx ON parc.version (commune);
-- La même géométrie sous deux identifiants = une parcelle renumérotée. C'est par
-- là qu'on rattrape une parcelle à travers une fusion de communes.
CREATE INDEX IF NOT EXISTS version_sha_idx     ON parc.version (sha);
-- Un préfixe autre que '000' est la trace d'une commune absorbée, exactement
-- comme pour les sections cadastrales du pipeline communes.
CREATE INDEX IF NOT EXISTS version_prefixe_idx ON parc.version (commune, prefixe)
  WHERE prefixe <> '000';

COMMENT ON COLUMN parc.version.vu_fin IS
  'Dernier relevé où cet état a été observé, NULL si encore ouvert. Ce n''est PAS une date de disparition.';
COMMENT ON COLUMN parc.version.cree_source IS
  'Date de création déclarée par le cadastre. Antérieure à nos relevés : seule fenêtre sur l''avant-2018.';

-- --------------------------------------------------------------------------
-- Gabarit de la table de transit de l'ingestion.
--
-- Cette table-ci n'est jamais remplie : chaque département en cours de traitement
-- s'en fait une copie dans son propre schéma (`CREATE TABLE ... LIKE`). Sans
-- cette séparation, deux ingestions concurrentes écriraient dans la même table
-- et mélangeraient leurs relevés — ce qui s'est déjà produit accidentellement
-- avec un ogr2ogr orphelin, et n'a été rattrapé que par le garde-fou sur les
-- doublons. La définition des colonnes, elle, reste ici et à un seul endroit.
--
-- Pas de contrainte, pas d'index : on la remplit en COPY et on la lit une fois.
--
-- `arpente` est en text et pas en boolean, délibérément : le GeoJSON porte un
-- vrai booléen JSON, le shapefile un champ logique DBF que GDAL remonte tantôt
-- en entier, tantôt en 'T'/'F'. Un entier n'a pas de cast implicite vers boolean
-- en Postgres et ferait planter le COPY. On absorbe la variabilité au cast.
--
-- Pas de colonne d'identifiant technique : `ogr2ogr -append` dans une table
-- préexistante ne renseigne PAS le champ FID, contrairement à ce qu'il fait
-- quand il crée la table lui-même. Une colonne ogc_fid resterait NULL sur
-- toutes les lignes — et un dédoublonnage qui s'appuierait dessus ne
-- supprimerait jamais rien, silencieusement. On ordonne sur ctid.
-- --------------------------------------------------------------------------
DROP TABLE IF EXISTS raw.parcelles_stage;
CREATE TABLE raw.parcelles_stage (
  id         text,
  commune    text,
  prefixe    text,
  section    text,
  numero     text,
  contenance integer,
  arpente    text,
  created    date,
  updated    date,
  geom       geometry(MultiPolygon, 4326)
);

/** 'T' / 'true' / '1' / 1 → true, quelle que soit la façon dont GDAL l'a lu. */
CREATE OR REPLACE FUNCTION parc.en_booleen(t text)
RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE lower(nullif(trim(t), ''))
           WHEN 't' THEN true  WHEN 'true'  THEN true  WHEN '1' THEN true  WHEN 'y' THEN true
           WHEN 'f' THEN false WHEN 'false' THEN false WHEN '0' THEN false WHEN 'n' THEN false
         END;
$$;
