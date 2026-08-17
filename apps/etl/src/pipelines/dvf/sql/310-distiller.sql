-- =============================================================================
-- nexus-analytics — distillation d'une livraison DVF
-- =============================================================================
-- Même principe que parc.distiller : on ne stocke pas l'état livré, on stocke
-- l'écart avec ce qu'on savait déjà. Une ligne inchangée d'une livraison à
-- l'autre ne coûte pas une écriture.
--
-- Trois précautions, toutes tirées de mesures et non de principes.
--
--  1. L'ÉGALITÉ STRICTE EST ICI LÉGITIME. Sur les parcelles, comparer par
--     empreinte donnait 98 % de fausses modifications : la source republie des
--     coordonnées bruitées au centimètre. DVF ne contient que des valeurs
--     textuelles recopiées d'un acte — pas de recalcul, pas de bruit.
--
--  2. L'ABSENCE N'EST PAS UNE SUPPRESSION. Une livraison ne couvre que cinq ans.
--     Elle ne peut infirmer que les lignes dont la date tombe dans SA fenêtre ;
--     tout le reste est hors de son champ et doit être laissé intact. Sans cette
--     restriction, charger la livraison 2025 fermerait d'un coup tout 2014-2019.
--
--  3. L'ORDRE DU FICHIER EST UNE DONNÉE. Les lignes d'une même mutation sont
--     consécutives, et c'est la seule chose qui permette de les regrouper : le
--     champ qui identifierait l'acte est blanchi. On conserve donc `ordre` et on
--     ne trie jamais le stage avant d'avoir reconstruit les mutations.
-- =============================================================================

CREATE OR REPLACE FUNCTION dvf.distiller(
  p_publication date,
  p_schema      text DEFAULT 'raw'
) RETURNS TABLE (n_lignes bigint, n_ouvertures bigint, n_fermetures bigint)
LANGUAGE plpgsql AS $$
DECLARE
  v_debut date;
  v_fin   date;
  v_lignes bigint;
  v_ouv    bigint;
  v_ferm   bigint;
BEGIN
  -- Une livraison peut peser plusieurs millions de lignes ; on cadre la mémoire
  -- pour ne pas concurrencer les autres travaux de la machine.
  SET LOCAL work_mem = '64MB';
  SET LOCAL max_parallel_workers_per_gather = 1;
  SET LOCAL enable_parallel_hash = off;
  PERFORM set_config('search_path', p_schema || ', public', true);

  -- --------------------------------------------------------------------------
  -- Normalisation. Tout le typage se fait ici, une fois, en tolérant l'échec
  -- champ par champ (dvf.nombre) plutôt qu'en faisant tomber la livraison.
  -- --------------------------------------------------------------------------
  CREATE TEMP TABLE _norme ON COMMIT DROP AS
  SELECT s.ordre,
         to_date(s.date_mutation, 'DD/MM/YYYY')                       AS date_mutation,
         btrim(s.nature_mutation)                                     AS nature,
         dvf.nombre(s.valeur_fonciere)                                AS valeur,
         nullif(btrim(s.no_disposition), '')                          AS disposition,
         dvf.id_parcelle(s.code_departement, s.code_commune,
                         s.prefixe, s.section, s.no_plan)             AS id_parcelle,
         lpad(s.code_departement || lpad(s.code_commune, 3, '0'), 5, '0') AS commune,
         nullif(btrim(s.type_local), '')                              AS type_local,
         dvf.nombre(s.surface_bati)                                   AS surface_bati,
         dvf.nombre(s.nb_pieces)::smallint                            AS nb_pieces,
         dvf.nombre(s.nb_lots)::smallint                              AS nb_lots,
         nullif(btrim(s.lot1), '')                                    AS lot1,
         dvf.nombre(s.carrez1)                                        AS carrez1,
         nullif(btrim(s.no_volume), '')                               AS volume,
         nullif(btrim(s.nature_culture), '')                          AS culture,
         nullif(btrim(s.nature_culture_speciale), '')                 AS culture_speciale,
         dvf.nombre(s.surface_terrain)                                AS surface_terrain
    FROM dvf_stage s
   WHERE s.date_mutation IS NOT NULL
     AND s.code_departement IS NOT NULL
     AND s.section IS NOT NULL AND s.no_plan IS NOT NULL;

  SELECT min(date_mutation), max(date_mutation), count(*)
    INTO v_debut, v_fin, v_lignes FROM _norme;

  IF v_lignes = 0 THEN
    RAISE EXCEPTION 'livraison % : aucune ligne exploitable dans %.dvf_stage',
                    p_publication, p_schema;
  END IF;

  -- --------------------------------------------------------------------------
  -- Empreinte de contenu + rang d'occurrence.
  --
  -- Deux lignes rigoureusement identiques sont légitimes (deux dépendances
  -- semblables dans la même vente) : on les distingue par leur rang, dans
  -- l'ordre du fichier. C'est arbitraire mais stable — et c'est la seule façon
  -- de ne pas voir un doublon légitime osciller entre présent et absent d'une
  -- livraison à l'autre.
  -- --------------------------------------------------------------------------
  -- --------------------------------------------------------------------------
  -- Reconstruction des mutations, par CONTIGUÏTÉ.
  --
  -- Le champ qui identifierait l'acte (« Reference document ») est blanchi dans
  -- l'open data. Il ne reste que ceci : les lignes d'une même mutation sont
  -- consécutives dans le fichier et partagent date et valeur foncière.
  --
  -- Règle validée contre geo-dvf, qui publie le découpage d'Etalab (commune
  -- 01053, année 2021, 1 143 triplets appariés) : 994 blocs pour 996 mutations,
  -- 4 blocs recouvrant deux mutations, 2 mutations éclatées en deux blocs — soit
  -- 99,4 % d'accord. Le résidu est irréductible : deux ventes le même jour, au
  -- même prix, dans la même commune, que rien dans l'open data ne sépare.
  -- Etalab ne fait pas mieux, il tranche autrement.
  --
  -- La rupture est aussi forcée au changement de département : une mutation ne
  -- franchit pas la frontière de deux services de publicité foncière, et le
  -- fichier étant trié par département, deux ventes sans rapport se retrouvent
  -- voisines à chaque bordure.
  -- --------------------------------------------------------------------------
  CREATE TEMP TABLE _bloc ON COMMIT DROP AS
  WITH d AS (
    SELECT ordre, date_mutation, valeur, id_parcelle,
           CASE WHEN (date_mutation, valeur, parc.departement_de(commune))
                     IS DISTINCT FROM
                     lag((date_mutation, valeur, parc.departement_de(commune)))
                       OVER (ORDER BY ordre)
                THEN 1 ELSE 0 END AS debut
      FROM _norme),
  r AS (SELECT *, sum(debut) OVER (ORDER BY ordre) AS bloc FROM d)
  SELECT ordre, bloc FROM r;

  -- Identifiant lisible et déterministe : jour, plus petite parcelle concernée,
  -- et quatre caractères tirés du prix pour départager deux ventes du même jour
  -- sur la même parcelle.
  CREATE TEMP TABLE _mutation ON COMMIT DROP AS
  SELECT b.bloc,
         to_char(min(n.date_mutation), 'YYYYMMDD') || '-' || min(n.id_parcelle)
           || '-' || substr(md5(coalesce(min(n.valeur)::text, '')), 1, 4) AS id_mutation
    FROM _bloc b JOIN _norme n USING (ordre)
   GROUP BY b.bloc;

  CREATE INDEX ON _bloc (ordre);
  CREATE INDEX ON _mutation (bloc);
  ANALYZE _bloc; ANALYZE _mutation;

  CREATE TEMP TABLE _livre ON COMMIT DROP AS
  SELECT n.*,
         m.id_mutation,
         digest(concat_ws('|', date_mutation, nature, valeur, disposition,
                               id_parcelle, type_local, surface_bati, nb_pieces,
                               nb_lots, lot1, carrez1, volume, culture,
                               culture_speciale, surface_terrain), 'sha1') AS empreinte,
         digest(concat_ws('|', date_mutation, id_parcelle, disposition,
                               type_local), 'sha1')                        AS ancre
    FROM _norme n
    JOIN _bloc     b USING (ordre)
    JOIN _mutation m USING (bloc);

  ALTER TABLE _livre ADD COLUMN occurrence smallint;
  UPDATE _livre l SET occurrence = r.rn
    FROM (SELECT ordre, row_number() OVER (PARTITION BY empreinte ORDER BY ordre) AS rn
            FROM _livre) r
   WHERE r.ordre = l.ordre;

  CREATE INDEX ON _livre (empreinte, occurrence);
  ANALYZE _livre;

  -- --------------------------------------------------------------------------
  -- Fermetures. Restreintes à la fenêtre de la livraison : hors d'elle, cette
  -- livraison n'a rien à dire.
  -- --------------------------------------------------------------------------
  WITH ferme AS (
    UPDATE dvf.ligne g SET vu_fin = p_publication
     WHERE g.vu_fin IS NULL
       AND g.date_mutation BETWEEN v_debut AND v_fin
       AND NOT EXISTS (SELECT 1 FROM _livre l
                        WHERE l.empreinte = g.empreinte AND l.occurrence = g.occurrence)
    RETURNING 1)
  SELECT count(*) INTO v_ferm FROM ferme;

  -- --------------------------------------------------------------------------
  -- Ouvertures.
  -- --------------------------------------------------------------------------
  WITH ouvre AS (
    INSERT INTO dvf.ligne (
      empreinte, occurrence, ancre, vu_debut, id_mutation, date_mutation, nature,
      valeur, disposition, id_parcelle, commune, type_local, surface_bati,
      nb_pieces, nb_lots, lot1, carrez1, volume, culture, culture_speciale,
      surface_terrain)
    SELECT l.empreinte, l.occurrence, l.ancre, p_publication, l.id_mutation,
           l.date_mutation, l.nature, l.valeur, l.disposition, l.id_parcelle,
           l.commune, l.type_local, l.surface_bati, l.nb_pieces, l.nb_lots,
           l.lot1, l.carrez1, l.volume, l.culture, l.culture_speciale,
           l.surface_terrain
      FROM _livre l
     WHERE NOT EXISTS (SELECT 1 FROM dvf.ligne g
                        WHERE g.empreinte = l.empreinte
                          AND g.occurrence = l.occurrence
                          AND g.vu_fin IS NULL)
    RETURNING 1)
  SELECT count(*) INTO v_ouv FROM ouvre;

  -- --------------------------------------------------------------------------
  -- Rafraîchissement en place de l'identifiant de mutation.
  --
  -- Il ne fait pas partie de l'empreinte, à dessein : une mutation qui gagne une
  -- parcelle de numéro plus petit change d'identifiant sans qu'aucune de ses
  -- autres lignes n'ait bougé. L'inclure dans l'empreinte ferait fermer puis
  -- rouvrir des lignes intactes — exactement l'erreur commise sur les dates
  -- déclarées des parcelles, qui produisait 82 390 faux changements par relevé.
  -- --------------------------------------------------------------------------
  UPDATE dvf.ligne g SET id_mutation = l.id_mutation
    FROM _livre l
   WHERE g.empreinte = l.empreinte AND g.occurrence = l.occurrence
     AND g.vu_fin IS NULL
     AND g.id_mutation IS DISTINCT FROM l.id_mutation;

  INSERT INTO dvf.publication (publication, debut, fin, n_fichiers, n_lignes,
                               n_ouvertures, n_fermetures)
  VALUES (p_publication, v_debut, v_fin, 0, v_lignes, v_ouv, v_ferm)
  ON CONFLICT (publication) DO UPDATE
    SET debut = EXCLUDED.debut, fin = EXCLUDED.fin, n_lignes = EXCLUDED.n_lignes,
        n_ouvertures = EXCLUDED.n_ouvertures, n_fermetures = EXCLUDED.n_fermetures,
        charge_le = now();

  n_lignes := v_lignes; n_ouvertures := v_ouv; n_fermetures := v_ferm;
  RETURN NEXT;
END;
$$;
