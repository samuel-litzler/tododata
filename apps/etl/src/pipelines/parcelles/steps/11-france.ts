/**
 * Ingestion des parcelles de la France entière.
 *
 * Un run national dure des heures : tout est conçu pour qu'il puisse être coupé,
 * repris, et qu'un département en échec n'emporte pas les cent autres.
 *
 *   - Chaque département est indépendant. Un échec est journalisé et le run
 *     continue ; la liste des départements en échec est rappelée à la fin.
 *   - L'ingestion d'un département est elle-même reprise-able (parc.millesime).
 *     Relancer la commande après une coupure repart là où on s'était arrêté,
 *     sans retélécharger ni redistiller ce qui l'a déjà été.
 *   - Les fichiers sources sont purgés au fil de l'eau. 6,5 Go pour la seule
 *     Moselle, ~420 Go pour la France : les conserver dépasserait le disque
 *     disponible à côté d'une base de ~95 Go.
 *
 * La concurrence est bornée par la ressource la plus contrainte, qui n'est ni le
 * CPU ni la RAM mais les entrées-sorties : trois COPY de 250 Mo en parallèle
 * saturent déjà le disque, et monter plus haut allonge tout le monde sans rien
 * gagner.
 */
import { listerObjets } from '../../../_shared/acquisition/cadastreCatalog.js'
import { ingererParcelles } from './10-ingerer.js'
import { pool } from '../../../_shared/db/pgClient.js'
import { logger } from '../../../_shared/observability/logger.js'

const BUCKET_ROOT = 'etalab-cadastre'

/** Les départements réellement publiés, lus au dernier millésime disponible. */
async function listerDepartements(): Promise<string[]> {
  const { rows } = await pool.query<{ millesime: string }>(
    `SELECT to_char(max(millesime), 'YYYY-MM-DD') AS millesime FROM parc.millesime`,
  )
  // Au tout premier run la base est vide : on prend un millésime récent connu
  // pour énumérer, le catalogue fera foi ensuite département par département.
  const millesime = rows[0]?.millesime ?? '2026-06-01'

  const objets = await listerObjets(`${BUCKET_ROOT}/${millesime}/geojson/departements/`)
  const deps = new Set<string>()
  for (const o of objets) {
    const m = o.key.match(/\/departements\/([^/]+)\//)
    if (m?.[1]) deps.add(m[1])
  }
  return [...deps].sort()
}

export async function ingererFrance(concurrence = 3, seulement?: string[]): Promise<void> {
  const departements = seulement?.length ? seulement : await listerDepartements()

  // Ce qui est déjà fait, pour annoncer un reste-à-faire honnête plutôt qu'un
  // pourcentage qui repartirait de zéro à chaque reprise.
  const { rows: faits } = await pool.query<{ departement: string; n: number }>(
    `SELECT departement, count(*)::int AS n FROM parc.millesime GROUP BY departement`,
  )
  const avancement = new Map(faits.map((r) => [r.departement, r.n]))

  logger.info(
    `France : ${departements.length} départements, ${avancement.size} déjà entamé(s), ` +
      `${concurrence} en parallèle`,
  )

  const file = [...departements]
  const echecs: { departement: string; raison: string }[] = []
  let termines = 0
  const debutRun = Date.now()

  async function travailleur(no: number): Promise<void> {
    for (;;) {
      const dep = file.shift()
      if (!dep) return
      const debut = Date.now()
      try {
        await ingererParcelles(dep, { purger: true })
        termines++
        const ecoule = (Date.now() - debutRun) / 60000
        // Tant que moins de départements sont terminés qu'il n'y a de fils, le
        // débit observé est faussé : plusieurs départements sont presque finis
        // mais aucun n'a encore été compté. Annoncer un reste à ce stade produit
        // un chiffre absurde — le premier run affichait 99 heures pour un travail
        // de 44. On se tait jusqu'à ce que la mesure ait un sens.
        const reste =
          termines >= concurrence
            ? ` · reste ~${(((departements.length - termines) * ecoule) / termines / 60).toFixed(1)} h`
            : ''
        logger.info(
          `[${no}] ${dep} terminé en ${((Date.now() - debut) / 60000).toFixed(1)} min · ` +
            `${termines}/${departements.length}${reste}`,
        )
      } catch (e) {
        const raison = e instanceof Error ? e.message : String(e)
        echecs.push({ departement: dep, raison })
        // On ne relance pas : un département en échec a de bonnes chances
        // d'échouer à nouveau pour la même raison, et le run doit avancer.
        // Il sera repris par une relance de la commande, une fois la cause levée.
        logger.error(`[${no}] ${dep} en échec : ${raison}`)
      }
    }
  }

  await Promise.all(
    Array.from({ length: Math.max(1, concurrence) }, (_, i) => travailleur(i + 1)),
  )

  const duree = ((Date.now() - debutRun) / 3600000).toFixed(1)
  logger.info(`France : ${termines}/${departements.length} départements en ${duree} h`)

  if (echecs.length) {
    logger.warn(`${echecs.length} département(s) en échec :`)
    for (const e of echecs) logger.warn(`  ${e.departement} — ${e.raison}`)
    logger.warn('Relancer la commande les reprendra là où ils se sont arrêtés.')
    process.exitCode = 1
  }
}
