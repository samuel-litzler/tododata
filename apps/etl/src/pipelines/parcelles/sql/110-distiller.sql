-- =============================================================================
-- nexus-analytics — distillation d'un relevé de parcelles
-- =============================================================================
-- Confronte parcelles_stage (un relevé fraîchement chargé par ogr2ogr) à
-- l'état courant de parc.version, et n'écrit QUE les différences.
--
-- Le point de conception à ne pas perdre de vue : à chaque millésime, ~99,95%
-- des parcelles sont inchangées. Un SCD2 naïf repousserait une date de fin sur
-- ces 1,5 M de lignes à chaque relevé — 48 M d'UPDATE et autant de tuples morts
-- sur l'ensemble du département. Ici « inchangé » ne coûte AUCUNE écriture :
-- c'est vu_fin IS NULL qui porte l'ouverture, et on n'y touche qu'à la fermeture.
--
-- ---------------------------------------------------------------------------
-- POURQUOI « INCHANGÉ » NE VEUT PAS DIRE « IDENTIQUE »
-- ---------------------------------------------------------------------------
-- Première version de ce script : deux parcelles étaient réputées identiques si
-- leurs géométries avaient la même empreinte de contenu. Résultat sur le premier
-- couple de relevés réels (2018-04-03 → 2018-06-29, tous deux en shapefile,
-- tous deux en Lambert-93) : 1 510 842 parcelles « modifiées » sur 1 539 828.
--
-- Ce n'est pas le cadastre qui a bougé. En comparant les WKT bruts, avant toute
-- reprojection, on voit que la source republie ses coordonnées avec un bruit de
-- l'ordre du centimètre — certains sommets sont identiques au bit près, leurs
-- voisins glissent de 7 à 11 mm. La distribution des écarts est sans ambiguïté :
--
--     identique      0,77 %
--     < 5 cm        99,17 %      ← le bruit de republication
--     5 - 25 cm      0,02 %
--     25 cm - 1 m    0,04 %      ← les vrais mouvements commencent ici
--     > 1 m          0,01 %
--
-- Aucune astuce de hachage ne survit à ça. Arrondir sur une grille ne déplace
-- que le problème : avec un bruit ε et une grille G, chaque sommet a une chance
-- ~ε/G de basculer de case, et il suffit d'UN sommet sur vingt pour changer
-- l'empreinte. Il faudrait une grille de 20 m pour rendre le hachage stable —
-- soit plus grand que beaucoup de parcelles.
--
-- La comparaison est donc géométrique et TOLÉRANTE : deux dessins sont le même
-- tant qu'aucun point de leur contour ne s'écarte de plus de 25 cm. Le seuil est
-- choisi dans le creux de la distribution ci-dessus, à plus de 20 fois le bruit
-- moyen et bien en deçà de tout mouvement cadastral réel. Le compromis est
-- assumé dans ce sens-là : une fausse modification pollue durablement la fiche
-- d'une parcelle, un ajustement de 10 cm non signalé n'intéresse personne.
--
-- L'empreinte de contenu, elle, n'est pas abandonnée : elle sert à repérer une
-- parcelle renumérotée à l'intérieur d'un même relevé — là où les coordonnées
-- viennent du même fichier et où l'égalité stricte redevient légitime.
--
-- À appeler dans l'ordre chronologique. La fonction refuse de reculer.
-- =============================================================================

/**
 * Projection métrique adaptée au territoire, pour que « 25 cm » veuille dire
 * 25 cm. En degrés le seuil dériverait avec la latitude ; en Web Mercator il
 * serait gonflé de 50% en métropole.
 */
CREATE OR REPLACE FUNCTION parc.srid_metrique(p_dep text)
RETURNS integer
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE p_dep
           WHEN '971' THEN 5490   -- Guadeloupe  (RGAF09 / UTM 20N)
           WHEN '972' THEN 5490   -- Martinique
           WHEN '973' THEN 2972   -- Guyane      (RGFG95 / UTM 22N)
           WHEN '974' THEN 2975   -- La Réunion  (RGR92 / UTM 40S)
           WHEN '976' THEN 4471   -- Mayotte     (RGM04 / UTM 38S)
           ELSE 2154              -- métropole   (RGF93 / Lambert-93)
         END;
$$;

/**
 * Département d'un code commune.
 *
 * Trois caractères outre-mer, deux ailleurs — Corse comprise ('2A004' → '2A').
 * Prendre bêtement les deux premiers caractères d'un code guadeloupéen donne
 * '97', que parc.srid_metrique ne reconnaît pas et qui retombe alors sur le
 * Lambert-93 métropolitain. Les surfaces de filiation outre-mer seraient fausses,
 * silencieusement.
 */
CREATE OR REPLACE FUNCTION parc.departement_de(p_commune text)
RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE WHEN left(p_commune, 2) = '97' THEN left(p_commune, 3)
              ELSE left(p_commune, 2) END;
$$;

/** Tolérance de comparaison, en mètres. Voir l'en-tête pour sa justification. */
CREATE OR REPLACE FUNCTION parc.tolerance_m() RETURNS double precision
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$ SELECT 0.25::double precision $$;

-- La signature change : sans DROP explicite, Postgres créerait une SURCHARGE et
-- l'appelant continuerait d'atteindre l'ancienne version selon ses arguments.
-- La signature change à nouveau : DROP explicite de toutes les formes connues.
DROP FUNCTION IF EXISTS parc.distiller(text, date, text);
DROP FUNCTION IF EXISTS parc.distiller(text, date, text, text, bigint, timestamptz);

CREATE OR REPLACE FUNCTION parc.distiller(
  p_dep       text,
  p_millesime date,
  p_format    text,
  p_etag      text        DEFAULT NULL,
  p_taille    bigint      DEFAULT NULL,
  p_publie_le timestamptz DEFAULT NULL,
  -- Schéma de travail. Un par département en cours de traitement : sans ça, deux
  -- ingestions concurrentes écriraient dans la même table de transit et
  -- mélangeraient leurs relevés. C'est ce qui permet de traiter la France en
  -- plusieurs fils au lieu de 34 heures en série.
  p_schema    text        DEFAULT 'raw'
)
RETURNS TABLE (
  n_parcelles    integer,
  n_ouvertures   integer,
  n_fermetures   integer,
  n_disparitions integer
)
LANGUAGE plpgsql AS $fn$
DECLARE
  v_precedent date;
  v_debut     timestamptz := clock_timestamp();
  v_srid      integer := parc.srid_metrique(p_dep);
  v_tol       double precision := parc.tolerance_m();
  v_n_parc    integer;
  v_n_ouv     integer;
  v_n_ferm    integer;
  v_n_disp    integer;
  v_n_dbl     integer;
  v_n_parc_brut integer;
BEGIN
  -- --- Cadrage des ressources ----------------------------------------------
  -- La comparaison confronte 1,5 M de géométries à 1,5 M d'autres. Laissée au
  -- réglage global (work_mem 96 Mo × 4 workers), Postgres bâtit une table de
  -- hachage parallèle de plusieurs centaines de Mo en MÉMOIRE PARTAGÉE — et le
  -- /dev/shm d'un conteneur Docker, même porté à 1 Go, finit par céder :
  -- « could not resize shared memory segment ». On borne donc explicitement.
  -- Déborder sur disque ici ne coûte que du temps, et le disque, on en a.
  SET LOCAL work_mem = '64MB';
  SET LOCAL max_parallel_workers_per_gather = 1;

  -- Le hachage parallèle bâtit sa table en MÉMOIRE PARTAGÉE (dynamic shared
  -- memory), dimensionnée par work_mem × participants. Un seul département tient
  -- dans le gigaoctet de /dev/shm du conteneur ; trois en parallèle, non — le run
  -- national l'a démontré sur l'Aveyron : « could not resize shared memory
  -- segment to 134217728 bytes: No space left on device ».
  --
  -- On désactive donc ce mode : le hachage se fait alors dans la mémoire privée
  -- de chaque backend, qui déborde sur disque au lieu de saturer un espace
  -- partagé et commun aux trois départements. C'est plus lent en théorie, sans
  -- effet mesurable ici — la distillation est bornée par le disque, pas par le
  -- processeur.
  SET LOCAL enable_parallel_hash = off;

  -- Toutes les tables de travail sont désormais NON QUALIFIÉES : elles se créent
  -- et se lisent dans le schéma du département en cours. Seules les tables
  -- durables (parc.*) restent explicitement qualifiées, pour qu'aucune faute de
  -- search_path ne puisse les faire écrire ailleurs.
  PERFORM set_config('search_path', p_schema || ', public', true);

  -- --- Garde-fous ----------------------------------------------------------
  SELECT max(millesime) INTO v_precedent
    FROM parc.millesime WHERE departement = p_dep;

  IF v_precedent IS NOT NULL AND p_millesime <= v_precedent THEN
    RAISE EXCEPTION
      'distillation hors ordre : % déjà traité jusqu''à % pour le département %',
      p_millesime, v_precedent, p_dep;
  END IF;

  -- Le département est déduit du code commune, jamais d'un champ du fichier :
  -- on veut détecter une parcelle qui aurait migré vers un autre département.
  IF EXISTS (SELECT 1 FROM parcelles_stage WHERE commune NOT LIKE p_dep || '%') THEN
    RAISE EXCEPTION 'le relevé contient des communes hors du département %', p_dep;
  END IF;

  -- --- 1. Normalisation du relevé -----------------------------------------
  -- Table réelle et non TEMP : Postgres ne parallélise pas un CTAS temporaire.
  -- UNLOGGED : contenu jetable, reconstruit à chaque relevé.
  DROP TABLE IF EXISTS parcelles_entree;
  CREATE UNLOGGED TABLE parcelles_entree AS
  -- ctid ne peut pas nommer une colonne utilisateur : on l'aliase. Il reflète
  -- l'ordre physique d'insertion, ce qui suffit à départager deux doublons.
  -- La DÉCOMPOSITION EST DÉRIVÉE DE L'IDENTIFIANT quand le champ manque.
  --
  -- L'identifiant est la concaténation canonique commune(5) + préfixe(3) +
  -- section(2) + numéro(4), et c'est lui qui fait foi : sur le premier relevé de
  -- l'Ardèche, deux parcelles sur 1 270 084 portent un `numero` à blanc dans le
  -- DBF alors que leur identifiant se termine bien par « 0000 ». Le champ est
  -- vide, la donnée ne l'est pas.
  --
  -- Le zéro de tête est retiré pour rester cohérent avec le champ nominal, qui
  -- livre « 28 » là où l'identifiant écrit « 0028 ». Le préfixe, lui, garde son
  -- rembourrage : « 000 » y est une valeur, pas un remplissage.
  SELECT s.ctid AS ordre_source, s.id,
         coalesce(nullif(s.commune, ''), substring(s.id, 1, 5))  AS commune,
         coalesce(nullif(s.prefixe, ''), substring(s.id, 6, 3))  AS prefixe,
         coalesce(nullif(s.section, ''),
                  nullif(ltrim(substring(s.id, 9, 2), '0'), ''), '0') AS section,
         coalesce(nullif(s.numero, ''),
                  nullif(ltrim(substring(s.id, 11, 4), '0'), ''), '0') AS numero,
         -- Une contenance absente s'écrit '.' dans le DBF ; GDAL la lit 0. En
         -- GeoJSON la même absence donne null. Sans normalisation, la bascule de
         -- format de juillet 2022 ferait passer ces parcelles pour modifiées.
         -- Et 0 m² n'est de toute façon pas une contenance : c'est une absence.
         nullif(s.contenance, 0) AS contenance,
         parc.en_booleen(s.arpente) AS arpente,
         s.created, s.updated, s.geom
    FROM parcelles_stage s
   -- L'identifiant doit être exploitable : sans lui, ni identité ni décomposition
   -- de secours. Une ligne qui n'a ni géométrie ni identifiant valide n'est pas
   -- une parcelle.
   WHERE s.geom IS NOT NULL AND s.id IS NOT NULL AND length(s.id) = 14;

  SELECT count(*) INTO v_n_parc_brut FROM parcelles_entree;
  CREATE INDEX ON parcelles_entree (id, ordre_source);

  -- Dédoublonnage défensif, volontairement fait APRÈS coup et pas via un
  -- DISTINCT ON : ce dernier imposerait un tri de 1,5 M de lignes portant la
  -- géométrie, soit plusieurs Go de fichiers temporaires, pour un cas de figure
  -- qui ne se présente peut-être jamais. Ici on ne paie que s'il y a des doublons.
  DELETE FROM parcelles_entree a
   WHERE EXISTS (SELECT 1 FROM parcelles_entree b
                  WHERE b.id = a.id AND b.ordre_source < a.ordre_source);
  GET DIAGNOSTICS v_n_dbl = ROW_COUNT;

  -- Quelques doublons, c'est une bizarrerie de la source : on la note et on
  -- avance. Des dizaines de milliers, c'est que la table de travail contient
  -- autre chose que le relevé attendu — typiquement un chargement précédent
  -- interrompu dont l'ogr2ogr écrivait encore. Le silence serait ici la pire
  -- des options : on refuserait de distiller des données qu'on ne comprend pas.
  IF v_n_dbl > v_n_parc_brut * 0.01 THEN
    RAISE EXCEPTION
      'table de travail incohérente pour % : % doublons sur % lignes chargées. '
      'Un chargement concurrent ou interrompu est le suspect habituel.',
      p_millesime, v_n_dbl, v_n_parc_brut;
  ELSIF v_n_dbl > 0 THEN
    RAISE WARNING '% : % identifiant(s) livré(s) en double par la source, premier conservé',
      p_millesime, v_n_dbl;
  END IF;

  ANALYZE parcelles_entree;
  SELECT count(*) INTO v_n_parc FROM parcelles_entree;

  -- --- 2. Ce qui bouge -----------------------------------------------------
  -- Ne contient QUE les lignes qui appellent une écriture. Les ~99,95% de
  -- parcelles inchangées ne franchissent pas cette étape et ne coûtent rien
  -- au-delà du parcours.
  --
  -- RÈGLE DES ATTRIBUTS : une modification exige DEUX valeurs connues et
  -- différentes. Un attribut qui passe de connu à inconnu, ou d'inconnu à connu,
  -- n'a pas changé — c'est notre information sur lui qui a changé.
  --
  -- La distinction n'est pas théorique, elle a coûté un run complet. Le champ
  -- `arpente` n'existe QUE dans le GeoJSON : le shapefile (2018-04-03 →
  -- 2022-04-01) ne le porte pas, ogr2ogr laisse NULL. Première version de cette
  -- règle : on ne déclenchait pas sur un NULL entrant (« le format ne le dit
  -- plus »), mais on déclenchait sur le cas inverse. Résultat au relevé du
  -- 2022-07-01, quand le champ apparaît : 1 553 298 parcelles « modifiées » sur
  -- 1 557 169 — la totalité du département, le même jour, pour un attribut qui
  -- venait simplement d'être renseigné pour la première fois.
  --
  -- Les valeurs nouvellement connues ne sont pas perdues pour autant : elles sont
  -- reportées en place sur la version ouverte, juste après.
  DROP TABLE IF EXISTS parcelles_diff;
  CREATE UNLOGGED TABLE parcelles_diff AS
  SELECT e.id,
         v.no_version AS ancienne_version,
         (v.id_parcelle IS NULL) AS est_nouvelle,
         -- Valeurs retenues pour la version qu'on va ouvrir : celles du relevé,
         -- complétées par la dernière valeur connue quand le format ne les porte
         -- pas. Sans ce report, passer du GeoJSON au shapefile effacerait
         -- `arpente` de toutes les parcelles.
         coalesce(e.arpente, v.arpente)       AS arpente,
         coalesce(e.contenance, v.contenance) AS contenance
    FROM parcelles_entree e
    LEFT JOIN parc.version v
           ON v.id_parcelle = e.id
          AND v.vu_fin IS NULL
          -- Redondant avec la jointure sur l'identifiant, mais donne au planner
          -- de quoi élaguer quand parc.version portera les 95 départements.
          AND v.commune LIKE p_dep || '%'
   WHERE v.id_parcelle IS NULL                                   -- parcelle inconnue
      OR (v.contenance IS NOT NULL AND e.contenance IS NOT NULL
          AND v.contenance <> e.contenance)
      OR (v.arpente    IS NOT NULL AND e.arpente    IS NOT NULL
          AND v.arpente    <> e.arpente)
      -- Le test tolérant. Sur une parcelle inconnue, v.geom est NULL, la
      -- distance vaut NULL et le NULL > seuil aussi : c'est sans effet, la
      -- première condition a déjà retenu la ligne.
      OR ST_HausdorffDistance(ST_Transform(v.geom, v_srid),
                              ST_Transform(e.geom, v_srid)) > v_tol;

  CREATE INDEX ON parcelles_diff (id);
  ANALYZE parcelles_diff;

  -- Ce qui est appris sans être un changement, on l'enregistre EN PLACE.
  --
  -- Deux familles y passent :
  --   - `created` / `updated`, qui décrivent la FICHE administrative et non le
  --     terrain. Les avoir traitées comme un état a coûté 82 390 fausses
  --     modifications au seul relevé de juin 2018, à géométrie et contenance
  --     rigoureusement identiques : la source avait retouché ses métadonnées.
  --   - une valeur qui devient connue (voir la règle des attributs ci-dessus).
  --
  -- C'est bien une mutation de l'historique, et elle est assumée : ces champs
  -- disent ce que la source déclare AUJOURD'HUI de son enregistrement, pas ce que
  -- nous avons observé du territoire. Le coalesce va dans un seul sens — une
  -- valeur connue n'est jamais réeffacée par un format qui ne la porte pas.
  UPDATE parc.version v
     SET cree_source = coalesce(e.created,    v.cree_source),
         maj_source  = coalesce(e.updated,    v.maj_source),
         contenance  = coalesce(e.contenance, v.contenance),
         arpente     = coalesce(e.arpente,    v.arpente)
    FROM parcelles_entree e
   WHERE v.id_parcelle = e.id
     AND v.vu_fin IS NULL
     AND v.commune LIKE p_dep || '%'
     AND (v.cree_source IS DISTINCT FROM coalesce(e.created,    v.cree_source)
       OR v.maj_source  IS DISTINCT FROM coalesce(e.updated,    v.maj_source)
       OR v.contenance  IS DISTINCT FROM coalesce(e.contenance, v.contenance)
       OR v.arpente     IS DISTINCT FROM coalesce(e.arpente,    v.arpente))
     -- Inutile de retoucher une version qu'on s'apprête à fermer : sa remplaçante
     -- naîtra de toute façon avec les valeurs du relevé courant.
     AND NOT EXISTS (SELECT 1 FROM parcelles_diff d WHERE d.id = e.id);

  -- --- 3. Les versions à ouvrir, avec leur empreinte ----------------------
  -- Le hachage et le calcul de surface ne portent QUE sur ces quelques milliers
  -- de lignes. Les calculer sur les 1,5 M du relevé, comme le faisait la version
  -- précédente de ce script, représentait à lui seul l'essentiel du temps de
  -- traitement — pour un résultat inutile à la comparaison.
  DROP TABLE IF EXISTS parcelles_ouvrir;
  CREATE UNLOGGED TABLE parcelles_ouvrir AS
  SELECT e.id, e.commune, e.prefixe, e.section, e.numero,
         d.contenance, d.arpente, e.created, e.updated, e.geom,
         d.ancienne_version, d.est_nouvelle,
         parc.sha_geom(e.geom)       AS sha,
         ST_Area(e.geom::geography)  AS surface_m2
    FROM parcelles_entree e
    JOIN parcelles_diff d ON d.id = e.id;

  -- --- 4. Fermetures -------------------------------------------------------
  -- vu_fin porte le dernier relevé où l'état a été VU, donc le millésime
  -- précédent — pas celui qu'on est en train de traiter.
  UPDATE parc.version v
     SET vu_fin = v_precedent
    FROM parcelles_diff d
   WHERE v.id_parcelle = d.id
     AND v.no_version  = d.ancienne_version
     AND v.vu_fin IS NULL
     AND NOT d.est_nouvelle;
  GET DIAGNOSTICS v_n_ferm = ROW_COUNT;

  -- --- 5. Disparitions -----------------------------------------------------
  -- Ouverte au relevé précédent, absente de celui-ci. On ne qualifie rien ici
  -- (fusion ? renumérotation ? bug de source ?) : c'est le travail de l'étape
  -- filiation, qui a besoin de l'historique complet pour trancher.
  UPDATE parc.version v
     SET vu_fin = v_precedent
   WHERE v.vu_fin IS NULL
     AND v.commune LIKE p_dep || '%'
     AND NOT EXISTS (SELECT 1 FROM parcelles_entree e WHERE e.id = v.id_parcelle);
  GET DIAGNOSTICS v_n_disp = ROW_COUNT;

  -- --- 6. Ouvertures -------------------------------------------------------
  INSERT INTO parc.version (
    id_parcelle, no_version, geom, sha, surface_m2,
    commune, prefixe, section, numero,
    contenance, arpente, cree_source, maj_source,
    vu_debut, vu_fin
  )
  SELECT o.id,
         CASE
           -- Version suivante d'une parcelle qu'on vient de fermer : le numéro
           -- est connu, pas besoin d'aller le rechercher.
           WHEN NOT o.est_nouvelle THEN o.ancienne_version + 1
           -- Parcelle inconnue au relevé précédent. Elle peut malgré tout avoir
           -- un passé : disparue puis réapparue. Ce cas est rare, et au tout
           -- premier relevé la sous-requête porte sur une table vide.
           ELSE coalesce(
             (SELECT max(v2.no_version) FROM parc.version v2 WHERE v2.id_parcelle = o.id),
             0) + 1
         END,
         o.geom, o.sha, o.surface_m2,
         o.commune, o.prefixe, o.section, o.numero,
         o.contenance, o.arpente, o.created, o.updated,
         p_millesime, NULL
    FROM parcelles_ouvrir o;
  GET DIAGNOSTICS v_n_ouv = ROW_COUNT;

  -- --- 7. Journal ----------------------------------------------------------
  INSERT INTO parc.millesime (
    departement, millesime, format, n_parcelles,
    n_ouvertures, n_fermetures, n_disparitions, n_doublons, duree_ms,
    etag, taille, publie_le
  )
  VALUES (
    p_dep, p_millesime, p_format, v_n_parc,
    v_n_ouv, v_n_ferm, v_n_disp, v_n_dbl,
    (EXTRACT(epoch FROM clock_timestamp() - v_debut) * 1000)::integer,
    p_etag, p_taille, p_publie_le
  );

  DROP TABLE IF EXISTS parcelles_entree;
  DROP TABLE IF EXISTS parcelles_diff;
  DROP TABLE IF EXISTS parcelles_ouvrir;

  RETURN QUERY SELECT v_n_parc, v_n_ouv, v_n_ferm, v_n_disp;
END;
$fn$;
