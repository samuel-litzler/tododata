-- =============================================================================
-- nexus-analytics — rattachement des mutations à la vie des parcelles
-- =============================================================================
-- C'est ici que les deux jeux se rencontrent. DVF dit qu'une parcelle a changé
-- de main un jour donné ; le cadastre historisé dit ce qu'était cette parcelle
-- ce jour-là, et ce qu'elle est devenue depuis.
--
-- Le rattachement n'est pas supposé, il est QUALIFIÉ. Mesuré sur Bourg-en-Bresse
-- (12 621 lignes DVF, 2 185 parcelles) :
--
--   parcelles DVF retrouvées dans le parcellaire   2 185 / 2 185   100 %
--   présentes à la date même de la mutation        5 164 / 5 562    92,8 %
--   vendues avant notre première observation         395   (144 j de décalage moyen)
--   vendues après leur disparition                     0
--
-- Les 395 ne sont pas des erreurs : nos relevés sont trimestriels, une parcelle
-- créée puis vendue entre deux relevés est vendue « avant » qu'on la voie. Le
-- décalage moyen de 144 jours colle au pas d'observation. Et le zéro de la
-- dernière ligne est le vrai contrôle : aucune vente ne survient après la
-- disparition d'une parcelle, ce qui n'aurait aucun sens.
-- =============================================================================

DO $$
DECLARE
  v_dvf     int;
  v_couvert int;
BEGIN
  IF to_regclass('parc.parcelle') IS NULL THEN
    RAISE NOTICE 'parc.parcelle absente : rattachement ignoré. '
                 'Lancer parcelles:synthese d''abord.';
    RETURN;
  END IF;

  -- Garde-fou : parc.parcelle est une table DÉRIVÉE, reconstruite à la demande.
  -- Elle peut exister tout en ne couvrant pas les départements qu'on cherche à
  -- rattacher — c'est le cas dès qu'on ingère un département après la dernière
  -- synthèse. Le rattachement rendrait alors 100 % d'« inconnue », un résultat
  -- faux qui a toutes les apparences d'un résultat.
  --
  -- Même piège que le contrôle des préfixes, qui cherchait des communes
  -- disparues avant 2018 dans une table ne commençant qu'en 2018 : il ne
  -- mesurait que l'inadéquation de sa propre référence.
  -- Le test se fait par INTERVALLE sur `commune`, jamais par égalité sur une
  -- fonction des deux côtés : `parc.departement_de(p.commune) = …` interdirait
  -- l'index et rescannerait parc.parcelle pour chaque commune de DVF. Mesuré :
  -- dix minutes sans aboutir, contre un parcours d'index instantané ici.
  WITH deps AS (
    SELECT DISTINCT parc.departement_de(commune) AS dep FROM dvf.vente
  )
  SELECT count(*), count(*) FILTER (WHERE couvert)
    INTO v_dvf, v_couvert
    FROM deps d
    CROSS JOIN LATERAL (
      SELECT EXISTS (SELECT 1 FROM parc.parcelle p
                      WHERE p.commune >= d.dep AND p.commune < d.dep || 'Z') AS couvert
    ) c;

  IF v_couvert = 0 THEN
    RAISE NOTICE 'parc.parcelle ne couvre aucun des % département(s) présents dans DVF : '
                 'rattachement ignoré. Relancer parcelles:synthese.', v_dvf;
    RETURN;
  END IF;

  IF v_couvert < v_dvf THEN
    RAISE NOTICE 'parc.parcelle ne couvre que % des % départements présents dans DVF : '
                 'le rattachement sera partiel.', v_couvert, v_dvf;
  END IF;

  DROP TABLE IF EXISTS dvf.rattachement;

  -- Rattachement sur dvf.vente et non dvf.mutation_parcelle : c'est le grain
  -- stable. Voir 400-mutations.sql — l'autre voit ses clés se fermer et se
  -- rouvrir à chaque recomposition, ce qui ferait disparaître puis réapparaître
  -- des ventes qui n'ont jamais bougé.
  CREATE TABLE dvf.rattachement AS
  SELECT mp.date_mutation,
         mp.id_parcelle,
         mp.disposition,
         mp.commune,
         mp.avec_lots,
         mp.valeur,
         (p.id_parcelle IS NOT NULL) AS connue,
         CASE
           WHEN p.id_parcelle IS NULL                    THEN 'inconnue'
           WHEN mp.date_mutation < p.vu_premier          THEN 'anterieure_a_nos_releves'
           WHEN NOT p.presente
            AND mp.date_mutation > p.vu_dernier          THEN 'posterieure_a_sa_disparition'
           ELSE                                               'presente'
         END AS situation,
         -- Décalage entre la vente et notre première observation de la parcelle.
         -- Négatif quand la vente précède le relevé qui nous l'a fait connaître.
         (p.vu_premier - mp.date_mutation) AS jours_avant_observation,
         p.vu_premier,
         p.vu_dernier,
         p.presente
    FROM dvf.vente mp
    LEFT JOIN parc.parcelle p ON p.id_parcelle = mp.id_parcelle;

  ALTER TABLE dvf.rattachement ADD PRIMARY KEY (date_mutation, id_parcelle, disposition);
  CREATE INDEX ON dvf.rattachement (id_parcelle);
  CREATE INDEX ON dvf.rattachement (situation);

  ANALYZE dvf.rattachement;
END;
$$;

-- --------------------------------------------------------------------------
-- La dernière mutation connue d'un terrain, filiation comprise.
--
-- Sans la filiation, une parcelle née d'une division n'a jamais été vendue et
-- n'a donc pas de prix. C'est faux : son SOL a été vendu, sous un autre numéro.
-- On remonte donc d'une génération pour aller chercher la mutation du ou des
-- prédécesseurs, en conservant la part de surface héritée — un prix hérité d'un
-- prédécesseur dont on ne tient que 4 % n'a pas la même portée qu'un héritage
-- intégral.
--
-- Une seule génération, volontairement. Chaque saut supplémentaire dilue le lien
-- et le rend indéfendable ; mieux vaut ne rien dire que d'annoncer un prix au
-- mètre carré tiré d'un terrain qui n'a plus grand-chose à voir.
-- --------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regclass('parc.filiation') IS NULL THEN
    RAISE NOTICE 'parc.filiation absente : héritage de mutation ignoré.';
    RETURN;
  END IF;

  DROP TABLE IF EXISTS dvf.mutation_heritee;

  CREATE TABLE dvf.mutation_heritee AS
  WITH direct AS (
    SELECT DISTINCT ON (v.id_parcelle)
           v.id_parcelle, v.date_mutation, v.disposition, v.valeur, v.avec_lots
      FROM dvf.vente v
     WHERE v.vu_fin IS NULL          -- déclaration toujours en vigueur
     ORDER BY v.id_parcelle, v.date_mutation DESC
  )
  SELECT f.id_apres                      AS id_parcelle,
         d.date_mutation,
         d.disposition,
         d.valeur,
         d.avec_lots,
         f.id_avant                      AS herite_de,
         f.type                          AS filiation,
         f.part_apres                    AS part_heritee
    FROM parc.filiation f
    JOIN direct d ON d.id_parcelle = f.id_avant
    -- Uniquement pour les parcelles qui n'ont PAS de mutation à elles.
   WHERE NOT EXISTS (SELECT 1 FROM direct x WHERE x.id_parcelle = f.id_apres);

  ALTER TABLE dvf.mutation_heritee
    ADD PRIMARY KEY (id_parcelle, herite_de, date_mutation, disposition);
  CREATE INDEX ON dvf.mutation_heritee (id_parcelle);

  ANALYZE dvf.mutation_heritee;
END;
$$;
