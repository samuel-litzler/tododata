#!/usr/bin/env bash
# Charge la couche "communes" de TOUS les millésimes exploitables en un fichier national.
#
# Le cadastre Etalab a changé de structure deux fois :
#   2017-07-06 → 2018-01-02 : rien d'agrégé, uniquement geojson/communes/{dep}/{insee}/
#                              (~35 000 fichiers par millésime) → traité à part, pas ici.
#   2018-04-03 → 2022-04-01 : shp/france/cadastre-france-communes-shp.zip
#   2022-07-01 → 2026-06-01 : geojson/france/cadastre-france-communes.json.gz
set -uo pipefail

WORK=/home/bbw/data/nexus-cadastre/work
PG="PG:host=localhost port=5434 dbname=nexus user=nexus password=nexus_dev"
BASE="https://cadastre.data.gouv.fr/data/etalab-cadastre"
cd "$WORK"

SHP_MIL="2018-04-03 2018-06-29 2018-10-01 2019-01-01 2019-04-01 2019-07-01 2019-10-01 2020-01-01 2020-07-01 2020-10-01 2021-02-01 2021-04-01 2021-07-01 2021-10-01 2022-01-01 2022-04-01"
GJ_MIL="2022-07-01 2022-10-01 2023-01-01 2023-04-01 2023-07-01 2023-10-01 2024-01-01 2024-04-01 2024-07-01 2024-10-01 2025-01-01 2025-04-01 2025-09-01 2025-12-01 2026-03-01 2026-06-01"

load_one() {
  local mil="$1" kind="$2" file="$3" url="$4" src="$5"
  local table="communes_${mil//-/_}"

  # Idempotence : si la table existe déjà avec des lignes, on passe.
  local n
  n=$(docker exec nexus-database-dev psql -U nexus -d nexus -tAc \
      "SELECT coalesce((SELECT count(*) FROM raw.$table),0)" 2>/dev/null || echo 0)
  if [ "${n:-0}" -gt 0 ]; then
    echo "[$(date +%T)] $mil : déjà chargé ($n lignes), skip"
    return 0
  fi

  if [ ! -f "$file" ]; then
    echo "[$(date +%T)] $mil : téléchargement ($kind)"
    if ! curl -sL --max-time 1800 -o "$file.part" "$url"; then
      echo "[$(date +%T)] $mil : ECHEC téléchargement"; return 1
    fi
    mv "$file.part" "$file"
  fi

  echo "[$(date +%T)] $mil : chargement -> raw.$table"
  # SHAPE_ENCODING vide = laisse GDAL lire le .cpg du zip ; sinon il force du LATIN1
  # et les noms de communes accentués ressortent en mojibake.
  if ! SHAPE_ENCODING="" ogr2ogr -f PostgreSQL "$PG" "$src" \
      -nln "raw.$table" \
      -lco GEOMETRY_NAME=geom -lco FID=ogc_fid -lco SPATIAL_INDEX=NONE -lco PRECISION=NO \
      -nlt MULTIPOLYGON -a_srs EPSG:4326 \
      --config PG_USE_COPY YES -overwrite 2>&1 | tail -3; then
    echo "[$(date +%T)] $mil : ECHEC ogr2ogr"; return 1
  fi

  n=$(docker exec nexus-database-dev psql -U nexus -d nexus -tAc "SELECT count(*) FROM raw.$table")
  echo "[$(date +%T)] $mil : OK, $n communes"
}

for mil in $GJ_MIL; do
  f="$WORK/cadastre-france-communes-$mil.json.gz"
  load_one "$mil" geojson "$f" \
    "$BASE/$mil/geojson/france/cadastre-france-communes.json.gz" "/vsigzip/$f"
done

for mil in $SHP_MIL; do
  f="$WORK/cadastre-france-communes-$mil-shp.zip"
  load_one "$mil" shp "$f" \
    "$BASE/$mil/shp/france/cadastre-france-communes-shp.zip" "/vsizip/$f"
done

echo "[$(date +%T)] ===== TERMINÉ ====="
docker exec nexus-database-dev psql -U nexus -d nexus -c \
 "SELECT table_name, (xpath('/row/c/text()', query_to_xml('SELECT count(*) c FROM raw.'||table_name, false,true,'')))[1]::text::int AS n
  FROM information_schema.tables WHERE table_schema='raw' AND table_name LIKE 'communes_%' ORDER BY table_name;"
