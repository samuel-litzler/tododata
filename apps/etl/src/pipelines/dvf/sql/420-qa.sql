-- =============================================================================
-- nexus-analytics — contrôles du pipeline DVF
-- =============================================================================
-- Tout ce qui est montré doit être calculé ici, jamais dans le code de
-- restitution : sans quoi ce qu'on contrôle et ce qu'on affiche finissent par
-- diverger sans que personne ne s'en aperçoive.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS qa;

-- --------------------------------------------------------------------------
-- Ce que chaque livraison a changé.
--
-- La colonne qui compte est `n_fermetures` : ce sont les déclarations retirées.
-- Elles n'existent nulle part ailleurs — la DGFiP republie l'année en silence.
-- --------------------------------------------------------------------------
DROP TABLE IF EXISTS qa.dvf_livraison;
CREATE TABLE qa.dvf_livraison AS
SELECT p.publication,
       p.debut,
       p.fin,
       p.n_fichiers,
       p.n_lignes,
       p.n_ouvertures,
       p.n_fermetures,
       round(100.0 * p.n_fermetures / nullif(p.n_lignes, 0), 3) AS pct_retrait,
       round(100.0 * p.n_ouvertures / nullif(p.n_lignes, 0), 3) AS pct_nouveau,
       round(p.duree_ms / 1000.0)::int AS duree_s
  FROM dvf.publication p;

-- --------------------------------------------------------------------------
-- L'état d'une ANNÉE vu par chaque livraison qui la couvre.
--
-- C'est le tableau qui répond à « une année passée bouge-t-elle ? ». Une année
-- figée donnerait la même valeur sur toute sa ligne.
-- --------------------------------------------------------------------------
-- `complete` est indispensable à la lecture. Les livraisons d'octobre ne portent
-- que le premier semestre de l'année de tête et le second de l'année de queue :
-- comparer sans le savoir donnerait « 2019 : de 7 866 à 42 464 lignes », soit
-- une révision de 34 598 lignes qui n'est qu'un demi-fichier.
--
-- Les bornes étant MESURÉES sur les dates de mutation réellement présentes, une
-- année pleine ne commence pas au 1er janvier (2014 débute le 2) ni ne finit au
-- 31 décembre. On tolère donc un mois de part et d'autre.
DROP TABLE IF EXISTS qa.dvf_annee_par_livraison;
CREATE TABLE qa.dvf_annee_par_livraison AS
SELECT p.publication,
       extract(year FROM l.date_mutation)::int AS annee,
       (p.debut <= make_date(extract(year FROM l.date_mutation)::int, 1, 31)
        AND p.fin >= make_date(extract(year FROM l.date_mutation)::int, 12, 1)) AS complete,
       count(*)                                AS n_lignes,
       count(DISTINCT l.id_mutation)           AS n_mutations,
       sum(l.valeur) FILTER (WHERE l.type_local IS NULL) AS valeur_terrains
  FROM dvf.publication p
  JOIN dvf.ligne l
    ON l.date_mutation BETWEEN p.debut AND p.fin
   AND l.vu_debut <= p.publication
   AND (l.vu_fin IS NULL OR l.vu_fin > p.publication)
 GROUP BY 1, 2, 3;

-- --------------------------------------------------------------------------
-- Ventes avec et sans lots.
--
-- Le discriminant mesuré sur Bourg-en-Bresse : une vente de lots ne dit presque
-- rien du propriétaire du SOL, puisque la parcelle appartient à la copropriété.
-- On garde la répartition sous les yeux pour que la distinction ne se perde pas
-- en route.
-- --------------------------------------------------------------------------
DROP TABLE IF EXISTS qa.dvf_lots;
CREATE TABLE qa.dvf_lots AS
SELECT coalesce(m.nature, '(non renseignée)') AS nature,
       m.avec_lots,
       count(*)                    AS n_mutations,
       sum(m.n_parcelles)          AS n_parcelles,
       percentile_disc(0.5) WITHIN GROUP (ORDER BY m.valeur) AS valeur_mediane
  FROM dvf.mutation m
 WHERE m.vu_fin IS NULL
 GROUP BY 1, 2;

-- --------------------------------------------------------------------------
-- Qualité du rattachement au cadastre, quand celui-ci est disponible.
-- --------------------------------------------------------------------------
DROP TABLE IF EXISTS qa.dvf_rattachement;
CREATE TABLE qa.dvf_rattachement (situation text, n_couples bigint, n_parcelles bigint);

DO $$
BEGIN
  IF to_regclass('dvf.rattachement') IS NULL THEN RETURN; END IF;
  INSERT INTO qa.dvf_rattachement
  SELECT situation, count(*), count(DISTINCT id_parcelle)
    FROM dvf.rattachement GROUP BY 1;
END;
$$;

ANALYZE qa.dvf_livraison;
ANALYZE qa.dvf_annee_par_livraison;
ANALYZE qa.dvf_lots;
