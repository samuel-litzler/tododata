-- =============================================================================
-- nexus-analytics — extensions requises
-- Exécuté UNE SEULE FOIS, à l'initialisation du volume (docker-entrypoint-initdb.d).
-- Si tu ajoutes une extension ici après coup, elle ne sera PAS appliquée sur un
-- volume déjà initialisé : passe par une migration dans packages/db/migrations/.
-- =============================================================================

-- Cœur géospatial.
CREATE EXTENSION IF NOT EXISTS postgis;

-- ST_Subdivide, ST_ClusterDBSCAN… utilisés pour découper les géométries
-- communales trop denses avant comparaison (une commune peut faire >100k points).
CREATE EXTENSION IF NOT EXISTS postgis_raster;

-- Index composites (millesime, geom) : GIST ne sait pas indexer un scalaire
-- sans btree_gist. Indispensable pour les contraintes d'exclusion temporelles.
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- Recherche floue sur les noms de communes : la réconciliation cadastre <-> COG
-- doit rapprocher "SAINT-JEAN-DE-LUZ" / "Saint-Jean-de-Luz" / "St-Jean-de-Luz".
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS unaccent;

-- Traçabilité des runs ETL longs : identifie les requêtes qui coûtent le plus.
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Digests de géométries normalisées, pour dédupliquer les 36 millésimes
-- (95% des communes ne changent pas d'un millésime à l'autre).
CREATE EXTENSION IF NOT EXISTS pgcrypto;

DO $$
BEGIN
  RAISE NOTICE 'nexus-analytics: extensions installées (PostGIS %)', postgis_version();
END
$$;
