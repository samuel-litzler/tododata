#!/usr/bin/env bash
# Où en est le run national des parcelles ?
#
# À lancer à tout moment, y compris depuis un autre terminal ou après un
# redémarrage de session : le run est détaché (parent /init) et ne dépend
# d'aucune session interactive.
#
#   ./infra/etat-parcelles.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
set -a; . ./.env; set +a
export PGPASSWORD="$DB_PASSWORD"
PSQL="psql -h ${DB_HOST:-localhost} -p ${DB_PORT:-5434} -U $DB_USER -d $DB_NAME -tA"
LOG=/home/bbw/data/nexus-cadastre/work/france.log

if pgrep -f 'cli\.ts parcelles:france' > /dev/null 2>&1; then
  echo "▶  Run EN COURS  (démarré il y a $(ps -o etime= -p "$(pgrep -f 'cli\.ts parcelles:france' | head -1)" | tr -d ' '))"
else
  echo "■  Aucun run en cours."
fi

echo
$PSQL -c "
SELECT '   départements complets : ' || count(*) FILTER (WHERE n = 32) || ' / 101'
    || E'\n   départements entamés   : ' || count(*)
    || E'\n   relevés distillés      : ' || sum(n)
    || E'\n   parcelles suivies      : ' || to_char((SELECT count(*) FROM parc.version), 'FM999G999G999')
    || E'\n   taille en base         : ' || pg_size_pretty(pg_total_relation_size('parc.version'))
  FROM (SELECT departement, count(*) AS n FROM parc.millesime GROUP BY 1) t"

echo
echo "   disque : $(df -h / | tail -1 | awk '{print $4" libres sur "$2}')"

echo
echo "   5 derniers départements terminés :"
grep 'terminé en' "$LOG" 2>/dev/null | tail -5 | sed 's/.*"msg":"/     /; s/"}$//'

if grep -q 'en échec' "$LOG" 2>/dev/null; then
  echo
  echo "   ⚠  ÉCHECS :"
  grep 'en échec' "$LOG" | sed 's/.*"msg":"/     /; s/"}$//'
  echo "     → à relancer : pnpm --filter @nexus/etl exec tsx src/cli.ts parcelles:france 3 <dep>"
fi
