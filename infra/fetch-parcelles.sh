#!/usr/bin/env bash
# Télécharge la couche "parcelles" d'un département sur tous les millésimes.
#
# Contrairement aux communes, les parcelles ne sont JAMAIS publiées en agrégat
# national : c'est toujours geojson/departements/{dep}/ ou shp/departements/{dep}/.
# Les 3 millésimes de 2017 n'ont que du par-commune, ils sont hors périmètre ici.
#
# Usage : fetch-parcelles.sh <dep>          ex: fetch-parcelles.sh 57
set -uo pipefail

DEP="${1:?département requis, ex 57}"
WORK=/home/bbw/data/nexus-cadastre/work/parcelles
BASE="https://cadastre.s3.rbx.io.cloud.ovh.net/etalab-cadastre"
mkdir -p "$WORK"

SHP_MIL="2018-04-03 2018-06-29 2018-10-01 2019-01-01 2019-04-01 2019-07-01 2019-10-01 2020-01-01 2020-07-01 2020-10-01 2021-02-01 2021-04-01 2021-07-01 2021-10-01 2022-01-01 2022-04-01"
GJ_MIL="2022-07-01 2022-10-01 2023-01-01 2023-04-01 2023-07-01 2023-10-01 2024-01-01 2024-04-01 2024-07-01 2024-10-01 2025-01-01 2025-04-01 2025-09-01 2025-12-01 2026-03-01 2026-06-01"

get() {
  local mil="$1" file="$2" url="$3"
  [ -s "$file" ] && { echo "[$(date +%T)] $mil : déjà là"; return 0; }
  if ! curl -sL --max-time 1800 -o "$file.part" "$url"; then
    echo "[$(date +%T)] $mil : ECHEC téléchargement"; rm -f "$file.part"; return 1
  fi
  mv "$file.part" "$file"
  echo "[$(date +%T)] $mil : $(du -h "$file" | cut -f1)"
}

for mil in $GJ_MIL; do
  get "$mil" "$WORK/cadastre-$DEP-parcelles-$mil.json.gz" \
      "$BASE/$mil/geojson/departements/$DEP/cadastre-$DEP-parcelles.json.gz"
done
for mil in $SHP_MIL; do
  get "$mil" "$WORK/cadastre-$DEP-parcelles-$mil-shp.zip" \
      "$BASE/$mil/shp/departements/$DEP/cadastre-$DEP-parcelles-shp.zip"
done

echo "[$(date +%T)] ===== terminé — $(du -sh "$WORK" | cut -f1) ====="
