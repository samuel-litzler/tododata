-- =============================================================================
-- nexus-analytics — contrôle qualité du pipeline parcelles
-- =============================================================================
-- Ce fichier ne produit pas de la donnée métier : il produit de quoi DOUTER de
-- la donnée métier. Chaque table répond à une question qu'on doit se poser avant
-- d'afficher quoi que ce soit sur un site.
--
-- La question centrale est celle du taux de changement. Le modèle repose sur un
-- pari : d'un relevé à l'autre, presque rien ne bouge. Si un relevé fait bouger
-- 10% des parcelles, ce n'est pas le cadastre qui a tremblé, c'est notre chaîne
-- qui a un artefact — changement de format, de projection, d'encodage. On veut
-- que ça se voie immédiatement.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS qa;

-- --------------------------------------------------------------------------
-- Un relevé, une ligne : ce qu'il a apporté et ce qu'il a coûté.
-- --------------------------------------------------------------------------
DROP TABLE IF EXISTS qa.parcelles_releve;
CREATE TABLE qa.parcelles_releve AS
SELECT m.departement,
       m.millesime,
       m.format,
       m.n_parcelles,
       m.n_parcelles - lag(m.n_parcelles) OVER (PARTITION BY m.departement ORDER BY m.millesime)
         AS variation,
       m.n_ouvertures,
       m.n_fermetures,
       m.n_disparitions,
       m.n_doublons,
       -- Le ratio qui doit rester petit. Au premier relevé il vaut 1 par
       -- construction (tout est nouveau) : c'est attendu, pas une anomalie.
       round((m.n_ouvertures::numeric / nullif(m.n_parcelles, 0)) * 100, 3) AS pct_mouvement,
       round(m.duree_ms / 1000.0, 1) AS duree_s
  FROM parc.millesime m;

-- --------------------------------------------------------------------------
-- Confrontation de la géométrie à la contenance déclarée.
--
-- Deux mesures indépendantes du même objet : l'une vient du dessin, l'autre de
-- la déclaration administrative. Leur accord est le meilleur contrôle qu'on
-- puisse s'offrir sur la chaîne géométrique — un problème de projection ferait
-- exploser l'écart, pas le dériver doucement.
-- --------------------------------------------------------------------------
DROP TABLE IF EXISTS qa.parcelles_surface;
CREATE TABLE qa.parcelles_surface AS
WITH e AS (
  SELECT v.id_parcelle,
         v.contenance,
         v.surface_m2,
         abs(v.surface_m2 - v.contenance) / v.contenance AS ecart_relatif
    FROM parc.version v
   WHERE v.vu_fin IS NULL          -- l'état courant seulement
     AND v.contenance > 100        -- sous 100 m², l'arrondi de la contenance domine
)
SELECT count(*)                                              AS n,
       round(avg(ecart_relatif)::numeric, 4)                 AS ecart_moyen,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY ecart_relatif))::numeric, 4) AS ecart_median,
       round((percentile_cont(0.95) WITHIN GROUP (ORDER BY ecart_relatif))::numeric, 4) AS ecart_p95,
       count(*) FILTER (WHERE ecart_relatif > 0.10)          AS n_au_dela_10pct,
       count(*) FILTER (WHERE ecart_relatif > 0.50)          AS n_au_dela_50pct
  FROM e;

-- --------------------------------------------------------------------------
-- Ce que la source déclare vs ce qu'on a pu voir.
--
-- Toute parcelle créée avant notre premier relevé nous arrive déjà vieille. La
-- distribution des dates de création est donc une fenêtre — indirecte mais
-- réelle — sur l'histoire d'AVANT 2018, que la géométrie seule ne donne pas.
-- --------------------------------------------------------------------------
DROP TABLE IF EXISTS qa.parcelles_anciennete;
CREATE TABLE qa.parcelles_anciennete AS
SELECT extract(year FROM cree_source)::int AS annee_creation,
       count(*)                            AS n_parcelles,
       count(*) FILTER (WHERE presente)    AS n_encore_presentes
  FROM parc.parcelle
 WHERE cree_source IS NOT NULL
 GROUP BY 1
 ORDER BY 1;

-- --------------------------------------------------------------------------
-- Les préfixes non-'000' : la mémoire des communes absorbées, au niveau
-- parcellaire cette fois.
--
-- Le pipeline communes a établi que le préfixe d'une section cadastrale porte
-- le code INSEE de la commune absorbée — déduction validée à 93,6% de
-- recouvrement géométrique contre GEOFLA. Les parcelles portent le même préfixe.
-- C'est donc une seconde occasion, indépendante, de confronter cette hypothèse
-- au réel : le code que porte le préfixe doit être un code INSEE ayant réellement
-- existé dans ce département.
--
-- La référence est le COG historique de l'INSEE (insee.commune_depuis_1943), et
-- surtout PAS cad.observation. Cette dernière ne contient que les communes vues
-- par le cadastre depuis 2018 : une commune absorbée avant cette date en est
-- forcément absente, et l'y chercher revenait à vérifier que les communes
-- disparues n'ont pas disparu. Le premier jet donnait 2 préfixes attestés sur
-- 18 — un chiffre qui ne mesurait que l'inadéquation de la référence.
-- --------------------------------------------------------------------------
DROP TABLE IF EXISTS qa.parcelles_prefixe;
CREATE TABLE qa.parcelles_prefixe AS
SELECT p.commune,
       p.prefixe,
       -- Reconstitution du code INSEE supposé de la commune absorbée :
       -- département + préfixe.
       substring(p.commune, 1, 2) || p.prefixe AS insee_suppose,
       count(*) AS n_parcelles,
       -- Ce code INSEE a-t-il réellement désigné une commune, à un moment ou à
       -- un autre depuis 1943 ?
       EXISTS (SELECT 1 FROM insee.commune_depuis_1943 c
                WHERE c.com = substring(p.commune, 1, 2) || p.prefixe)
         AS insee_atteste,
       -- Le nom de cette commune, quand il existe : c'est ce que le site pourra
       -- afficher pour expliquer d'où vient un préfixe.
       (SELECT c.libelle FROM insee.commune_depuis_1943 c
         WHERE c.com = substring(p.commune, 1, 2) || p.prefixe
         ORDER BY c.date_debut DESC LIMIT 1) AS nom_suppose
  FROM parc.parcelle p
 WHERE p.prefixe <> '000'
 GROUP BY 1, 2, 3;

-- --------------------------------------------------------------------------
-- Trous de présence : disparue puis revenue. Sur les communes, 94 trous sur 95
-- se sont révélés être des défauts de la source et non de vrais rétablissements.
-- On s'attend au même phénomène ici, et on veut pouvoir le chiffrer.
-- --------------------------------------------------------------------------
DROP TABLE IF EXISTS qa.parcelles_trou;
CREATE TABLE qa.parcelles_trou AS
SELECT e.id_parcelle,
       e.millesime AS retour,
       (SELECT max(v.vu_fin) FROM parc.version v
         WHERE v.id_parcelle = e.id_parcelle AND v.vu_fin < e.millesime) AS derniere_vue
  FROM parc.evenement e
 WHERE e.type = 'reapparition';

ANALYZE qa.parcelles_releve;
ANALYZE qa.parcelles_prefixe;
