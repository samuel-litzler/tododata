#!/usr/bin/env bash
# Charge un fichier communes national dans le schéma raw.
# Usage: load-communes.sh <millesime>   ex: load-communes.sh 2026-06-01
set -euo pipefail

MIL="${1:?millesime requis, ex 2026-06-01}"
WORK=/home/bbw/data/nexus-cadastre/work
TABLE="communes_${MIL//-/_}"
FILE="$WORK/cadastre-france-communes-$MIL.json.gz"

cd "$WORK"

if [ ! -f "$FILE" ]; then
  echo "[$(date +%T)] téléchargement $MIL"
  curl -sL --max-time 1800 -o "$FILE.part" \
    "https://cadastre.data.gouv.fr/data/etalab-cadastre/$MIL/geojson/france/cadastre-france-communes.json.gz"
  gzip -t "$FILE.part"
  mv "$FILE.part" "$FILE"
fi

echo "[$(date +%T)] chargement -> raw.$TABLE"
ogr2ogr -f PostgreSQL \
  "PG:host=localhost port=5434 dbname=nexus user=nexus password=nexus_dev" \
  "/vsigzip/$FILE" \
  -nln "raw.$TABLE" \
  -lco GEOMETRY_NAME=geom -lco FID=ogc_fid -lco SPATIAL_INDEX=NONE -lco PRECISION=NO \
  -nlt MULTIPOLYGON -a_srs EPSG:4326 \
  --config PG_USE_COPY YES -overwrite

echo "[$(date +%T)] terminé"
docker exec nexus-database-dev psql -U nexus -d nexus -c \
  "SELECT count(*) AS n_communes, pg_size_pretty(pg_total_relation_size('raw.$TABLE')) AS taille FROM raw.$TABLE;"
