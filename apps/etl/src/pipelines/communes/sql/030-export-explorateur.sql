-- =============================================================================
-- 030 — Export compact pour l'explorateur statique HTML/JS
-- =============================================================================
-- Contrainte : la page doit fonctionner sans serveur ni requête réseau, donc
-- toutes les données sont embarquées. Astuce de compacité : la présence d'une
-- commune sur les 32 millésimes tient dans un seul entier (1 bit par millésime),
-- ce qui fait tenir les 35 430 communes en ~1 Mo au lieu de 1,1 million de lignes.
-- =============================================================================

-- Le résultat est écrit côté SERVEUR dans /work (volume monté), pas renvoyé sur
-- stdout : le pipe de `docker exec` tronque au-delà de ~1 Mo et l'export fait 3,6 Mo.
-- Invocation : psql -q -t -A -o /work/explorer-data.json -f 030-export-explorateur.sql
\set ON_ERROR_STOP on

SELECT json_build_object(

  'genere_le', now()::date,

  -- Les 32 millésimes, dans l'ordre. L'index dans ce tableau = position du bit.
  'millesimes', (SELECT json_agg(millesime ORDER BY rang) FROM cad.millesime),

  -- Une entrée par code INSEE vu au moins une fois dans le cadastre.
  --   p = masque de présence (observée OU comblée)
  --   c = masque des seules observations comblées (défaut de source)
  --   n = nom cadastral le plus récent
  'communes', (
    SELECT json_agg(json_build_array(t.code_insee, t.nom, t.p, t.c) ORDER BY t.code_insee)
    FROM (
      SELECT p.code_insee,
             (SELECT o.nom FROM cad.observation o
               WHERE o.code_insee = p.code_insee AND o.nom IS NOT NULL
               ORDER BY o.millesime DESC LIMIT 1) AS nom,
             bit_or(1::bigint << ((m.rang - 1)::int))                                        AS p,
             coalesce(bit_or(CASE WHEN p.origine='comblee'
                                  THEN 1::bigint << ((m.rang - 1)::int) END), 0)             AS c
      FROM cad.presence p JOIN cad.millesime m USING (millesime)
      GROUP BY p.code_insee
    ) t
  ),

  -- Identité administrative : périodes du COG depuis 1943, restreintes aux codes
  -- qui apparaissent dans le cadastre (sinon on embarque 42 000 lignes inutiles).
  'cog', (
    SELECT json_agg(json_build_array(c.com, c.libelle, c.date_debut, c.date_fin)
                    ORDER BY c.com, c.date_debut)
    FROM insee.commune_depuis_1943 c
    WHERE c.typecom = 'COM'
      AND EXISTS (SELECT 1 FROM cad.presence p WHERE p.code_insee = c.com)
  ),

  -- Mouvements INSEE touchant ces codes, en entrée comme en sortie.
  'mvt', (
    SELECT json_agg(json_build_array(v.mod, v.date_eff, v.com_av, v.libelle_av,
                                     v.com_ap, v.libelle_ap, v.typecom_av, v.typecom_ap)
                    ORDER BY v.date_eff, v.com_av)
    FROM insee.mvt_commune v
    WHERE v.date_eff >= '2010-01-01'
      AND (EXISTS (SELECT 1 FROM cad.presence p WHERE p.code_insee = v.com_av)
        OR EXISTS (SELECT 1 FROM cad.presence p WHERE p.code_insee = v.com_ap))
  ),

  -- Libellés officiels des codes MOD, pour l'affichage.
  'mods', json_build_object(
    '10','Changement de nom', '20','Création', '21','Rétablissement',
    '30','Suppression', '31','Fusion simple', '32','Création de commune nouvelle',
    '33','Fusion association', '34','Transformation de fusion association en fusion simple',
    '35','Suppression de commune déléguée',
    '41','Changement de code dû à un changement de département',
    '50','Changement de code dû à un transfert de chef-lieu',
    '70','Transformation de commune associée en commune déléguée',
    '71','Rétablissement de commune déléguée', '72','Création de commune déléguée'),

  -- Anomalies qualifiées, pour afficher un verdict par commune.
  'anomalies', (
    SELECT json_agg(json_build_array(a.code_insee, a.regle, a.niveau,
                                     a.detail->>'millesimes_manquants')
                    ORDER BY a.code_insee)
    FROM qa.anomalie a WHERE a.code_insee IS NOT NULL
  ),

  -- Codes du COG absents du cadastre, et arrondissements municipaux : les deux
  -- familles d'écarts structurels qu'il faut pouvoir expliquer dans l'interface.
  'sans_cadastre', (
    SELECT json_agg(json_build_array(c.com, c.libelle) ORDER BY c.com)
    FROM insee.commune_2026 c
    WHERE c.typecom='COM'
      AND NOT EXISTS (SELECT 1 FROM cad.presence p WHERE p.code_insee = c.com)
  ),
  'arm', (
    SELECT json_agg(json_build_array(c.com, c.libelle, c.comparent) ORDER BY c.com)
    FROM insee.commune_2026 c WHERE c.typecom='ARM'
  )
);
