-- =============================================================================
-- nexus-analytics — mutations, et leur rattachement aux parcelles
-- =============================================================================
-- dvf.ligne est un journal : une ligne par état d'une ligne DVF, sur une plage
-- de livraisons. Utile à écrire, pénible à interroger. On en dérive ici les
-- trois objets réellement consommables :
--
--   dvf.mutation           un acte, une ligne.
--   dvf.mutation_parcelle  le grain qui joint le cadastre : (acte, parcelle).
--   dvf.evenement          ce qui est ARRIVÉ, y compris aux déclarations
--                          elles-mêmes — retraits et corrections compris.
--
-- Entièrement reconstruit à chaque appel. Jamais une source de vérité.
-- =============================================================================

-- --------------------------------------------------------------------------
-- L'acte.
--
-- `avec_lots` n'est pas un détail de nomenclature, c'est le discriminant qui
-- rend le signal exploitable. Mesuré sur Bourg-en-Bresse en croisant DVF avec
-- le fichier des personnes morales, deux sources publiques indépendantes :
--
--   vente hors lots              78,4 % s'accompagnent d'un changement de
--                                propriétaire constaté côté personnes morales
--   vente de lots (copropriété)  23,7 %
--
-- L'explication est structurelle, pas statistique : quand un appartement se
-- vend, la PARCELLE appartient à la copropriété et ne change pas de main. Une
-- vente avec lots ne dit donc presque rien sur le propriétaire du sol, et
-- l'annoncer comme un changement de propriétaire serait faux trois fois sur
-- quatre.
-- --------------------------------------------------------------------------
DROP TABLE IF EXISTS dvf.mutation;
CREATE TABLE dvf.mutation AS
SELECT l.id_mutation,
       min(l.date_mutation)                        AS date_mutation,
       min(l.nature)                               AS nature,
       max(l.valeur)                               AS valeur,
       count(DISTINCT l.id_parcelle)::int          AS n_parcelles,
       count(*) FILTER (WHERE l.type_local IS NOT NULL)::int AS n_locaux,
       coalesce(sum(l.nb_lots) FILTER (WHERE l.type_local IS NOT NULL), 0)::int AS n_lots,
       array_remove(array_agg(DISTINCT l.type_local), NULL) AS types_locaux,
       array_agg(DISTINCT l.commune)               AS communes,
       sum(l.surface_bati)                         AS surface_bati,
       sum(l.surface_terrain)                      AS surface_terrain,
       bool_or(l.lot1 IS NOT NULL)                 AS avec_lots,
       min(l.vu_debut)                             AS vu_debut,
       -- Fermée seulement si TOUTES ses lignes le sont : une mutation dont il
       -- reste une ligne ouverte a été corrigée, pas retirée.
       CASE WHEN bool_or(l.vu_fin IS NULL) THEN NULL ELSE max(l.vu_fin) END AS vu_fin
  FROM dvf.ligne l
 GROUP BY l.id_mutation;

ALTER TABLE dvf.mutation ADD PRIMARY KEY (id_mutation);
CREATE INDEX ON dvf.mutation (date_mutation);
CREATE INDEX ON dvf.mutation (vu_fin) WHERE vu_fin IS NOT NULL;

-- --------------------------------------------------------------------------
-- Le grain de jointure avec le cadastre.
--
-- Une mutation porte souvent sur plusieurs parcelles, et une parcelle peut
-- figurer dans plusieurs lignes de la même mutation (un appartement, sa cave,
-- son garage). C'est ici qu'on retombe sur UNE ligne par (acte, parcelle) —
-- sans quoi compter les ventes reviendrait à compter les dépendances.
-- --------------------------------------------------------------------------
DROP TABLE IF EXISTS dvf.mutation_parcelle;
CREATE TABLE dvf.mutation_parcelle AS
SELECT l.id_mutation,
       l.id_parcelle,
       min(l.commune)                       AS commune,
       min(l.date_mutation)                 AS date_mutation,
       min(l.nature)                        AS nature,
       max(l.valeur)                        AS valeur_mutation,
       count(*)::int                        AS n_lignes,
       array_remove(array_agg(DISTINCT l.type_local), NULL) AS types,
       sum(l.surface_bati)                  AS surface_bati,
       sum(l.surface_terrain)               AS surface_terrain,
       bool_or(l.lot1 IS NOT NULL)          AS avec_lots,
       min(l.vu_debut)                      AS vu_debut,
       CASE WHEN bool_or(l.vu_fin IS NULL) THEN NULL ELSE max(l.vu_fin) END AS vu_fin
  FROM dvf.ligne l
 GROUP BY l.id_mutation, l.id_parcelle;

ALTER TABLE dvf.mutation_parcelle ADD PRIMARY KEY (id_mutation, id_parcelle);
CREATE INDEX ON dvf.mutation_parcelle (id_parcelle);
CREATE INDEX ON dvf.mutation_parcelle (commune, date_mutation);

-- --------------------------------------------------------------------------
-- LA VENTE — le grain stable, et la seule surface de jointure au cadastre.
--
-- dvf.mutation_parcelle ne convient pas pour ça, et la mesure le montre :
-- l'`id_mutation` dérivant du contenu, toute recomposition ferme l'ancienne clé
-- et en ouvre une neuve. 33 743 de ses fermetures sur 33 743 sont remplacées le
-- même jour sur la même parcelle — son `vu_fin` mesure du churn d'identifiant,
-- pas un retrait. Bâtir un rattachement là-dessus ferait disparaître puis
-- réapparaître des ventes qui n'ont jamais bougé.
--
-- Le grain retenu a été choisi sur mesure, entre trois candidats :
--
--   (date, parcelle)                0 disparition · fusionne 3 274 ventes distinctes
--   (date, parcelle, prix)          34 316 disparitions (9,5 %) — le prix est corrigé
--   (date, parcelle, disposition)   0 disparition · fusionne 2 318 ventes distinctes
--
-- Le troisième gagne : parfaitement stable sur 322 816 triplets, et il vient de
-- la source au lieu d'être dérivé. Sa limite est connue et bornée — deux actes
-- du même jour sur la même parcelle portent tous deux la disposition 000001, et
-- rien ne les sépare alors que le prix. On ne masque pas ce cas, on le compte :
-- `n_prix` supérieur à 1 le signale ligne à ligne.
--
-- Le prix reste donc un ATTRIBUT versionné, pas une clé.
-- --------------------------------------------------------------------------
DROP TABLE IF EXISTS dvf.vente;
CREATE TABLE dvf.vente AS
SELECT l.date_mutation,
       l.id_parcelle,
       coalesce(l.disposition, '')          AS disposition,
       min(l.commune)                       AS commune,
       min(l.nature)                        AS nature,
       -- Prix en vigueur au dernier état ; l'historique complet reste dans
       -- dvf.ligne et les corrections sont journalisées dans dvf.evenement.
       max(l.valeur) FILTER (WHERE l.vu_fin IS NULL) AS valeur,
       count(DISTINCT l.valeur) FILTER (WHERE l.vu_fin IS NULL) AS n_prix,
       count(DISTINCT l.valeur)             AS n_prix_vus,
       count(DISTINCT l.id_mutation)        AS n_actes,
       bool_or(l.lot1 IS NOT NULL) FILTER (WHERE l.vu_fin IS NULL) AS avec_lots,
       array_remove(array_agg(DISTINCT l.type_local)
                      FILTER (WHERE l.vu_fin IS NULL), NULL) AS types,
       sum(l.surface_bati)    FILTER (WHERE l.vu_fin IS NULL) AS surface_bati,
       sum(l.surface_terrain) FILTER (WHERE l.vu_fin IS NULL) AS surface_terrain,
       min(l.vu_debut)                      AS vu_debut,
       -- Vaut NULL sur la totalité des lignes par construction : aucune vente
       -- n'est jamais retirée de DVF (0 disparition sur 320 763 couples (date,
       -- parcelle) observés). La colonne est conservée pour que cette propriété
       -- reste VÉRIFIABLE plutôt que supposée — si elle se met un jour à se
       -- remplir, c'est que la DGFiP a changé de pratique.
       CASE WHEN bool_or(l.vu_fin IS NULL) THEN NULL ELSE max(l.vu_fin) END AS vu_fin,
       -- Retard de déclaration, en jours : borne la fraîcheur de tout ce qu'on
       -- peut dire d'un territoire.
       (min(l.vu_debut) - l.date_mutation)  AS retard_jours
  FROM dvf.ligne l
 GROUP BY l.date_mutation, l.id_parcelle, coalesce(l.disposition, '');

ALTER TABLE dvf.vente ADD PRIMARY KEY (date_mutation, id_parcelle, disposition);
CREATE INDEX ON dvf.vente (id_parcelle);
CREATE INDEX ON dvf.vente (commune, date_mutation);
CREATE INDEX ON dvf.vente (date_mutation) WHERE NOT avec_lots;

-- --------------------------------------------------------------------------
-- Les événements.
--
-- Deux natures de faits, qu'on ne mélange pas :
--
--   ce qui arrive au TERRAIN        une mutation : le bien change de main.
--   ce qui arrive à la DÉCLARATION  un retrait, une correction de prix.
--
-- Le second groupe n'existe que parce qu'on historise. La DGFiP ne publie pas
-- ses corrections : elle republie l'année, silencieusement. Sans les livraisons
-- successives, une vente déclarée puis retirée serait indiscernable d'une vente
-- qui n'a jamais eu lieu.
--
-- `publication` date le CONSTAT, pas le fait — même prudence que pour les
-- parcelles. Une vente de janvier 2018 constatée en octobre 2019 dit deux
-- choses : la vente, et le retard de vingt et un mois.
-- --------------------------------------------------------------------------
DROP TABLE IF EXISTS dvf.evenement;
CREATE TABLE dvf.evenement (
  id_parcelle   text NOT NULL,
  id_mutation   text NOT NULL,
  type          text NOT NULL,
  date_mutation date NOT NULL,
  publication   date NOT NULL,   -- livraison où le fait est constaté
  detail        jsonb
);

-- La mutation elle-même, datée de sa première apparition.
INSERT INTO dvf.evenement (id_parcelle, id_mutation, type, date_mutation, publication, detail)
SELECT mp.id_parcelle, mp.id_mutation, 'mutation', mp.date_mutation, mp.vu_debut,
       jsonb_strip_nulls(jsonb_build_object(
         'nature', mp.nature, 'valeur', mp.valeur_mutation,
         'avec_lots', mp.avec_lots, 'types', to_jsonb(mp.types),
         'surface_bati', mp.surface_bati, 'surface_terrain', mp.surface_terrain,
         -- Le retard de déclaration, en jours. C'est une donnée en soi : il
         -- borne la fraîcheur de tout ce qu'on peut dire d'un territoire.
         'retard_jours', (mp.vu_debut - mp.date_mutation)))
  FROM dvf.mutation_parcelle mp;

-- Le retrait : la déclaration a disparu d'une livraison qui couvrait sa date.
INSERT INTO dvf.evenement (id_parcelle, id_mutation, type, date_mutation, publication, detail)
SELECT mp.id_parcelle, mp.id_mutation, 'retrait', mp.date_mutation, mp.vu_fin,
       jsonb_build_object('valeur', mp.valeur_mutation, 'nature', mp.nature)
  FROM dvf.mutation_parcelle mp
 WHERE mp.vu_fin IS NOT NULL;

-- La correction : même ancre (date, parcelle, disposition, type de local), mais
-- un contenu qui change d'une livraison à l'autre. C'est ce que l'ancre, plus
-- grossière que l'empreinte, est faite pour rendre visible.
INSERT INTO dvf.evenement (id_parcelle, id_mutation, type, date_mutation, publication, detail)
SELECT a.id_parcelle, a.id_mutation, 'correction', a.date_mutation, n.vu_debut,
       jsonb_strip_nulls(jsonb_build_object(
         'valeur_avant', a.valeur,        'valeur_apres', n.valeur,
         'surface_avant', a.surface_bati, 'surface_apres', n.surface_bati))
  FROM dvf.ligne a
  JOIN dvf.ligne n ON n.ancre = a.ancre
                  AND n.vu_debut = a.vu_fin        -- l'une remplace l'autre
                  AND n.empreinte <> a.empreinte
 WHERE a.vu_fin IS NOT NULL
   AND (a.valeur IS DISTINCT FROM n.valeur OR a.surface_bati IS DISTINCT FROM n.surface_bati);

CREATE INDEX ON dvf.evenement (id_parcelle, date_mutation);
CREATE INDEX ON dvf.evenement (type, publication);

ANALYZE dvf.mutation;
ANALYZE dvf.mutation_parcelle;
ANALYZE dvf.evenement;
