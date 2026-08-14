/**
 * Point d'entrée de l'ETL.
 *
 *   pnpm etl millesimes                      liste les millésimes publiés
 *   pnpm etl catalogue <millesime> [couche]  résout le fichier source et sa taille
 *   pnpm etl migrer                          applique les scripts SQL du pipeline communes
 *   pnpm etl referentiel                     charge les départements et régions de l'INSEE
 *
 * Chaque commande est idempotente : la relancer ne doit rien casser.
 */
import { listerMillesimes, fichierNational, strategiePour, type Couche } from './_shared/acquisition/cadastreCatalog.js'
import { appliquerMigrations } from './pipelines/communes/steps/01-migrer.js'
import { chargerReferentiel } from './pipelines/communes/steps/02-referentiel.js'
import { logger } from './_shared/observability/logger.js'
import { fermer } from './_shared/db/pgClient.js'

const ko = (n: number) => (n / 1024 ** 2).toFixed(1) + ' Mo'

async function main() {
  const [commande, ...args] = process.argv.slice(2)

  switch (commande) {
    case 'millesimes': {
      const ms = await listerMillesimes()
      logger.info(`${ms.length} millésimes publiés, de ${ms[0]} à ${ms.at(-1)}`)
      for (const m of ms) logger.info(`  ${m}  →  ${strategiePour(m)}`)
      break
    }

    case 'catalogue': {
      const millesime = args[0]
      if (!millesime) throw new Error('usage : catalogue <millesime> [couche]')
      const couche = (args[1] ?? 'communes') as Couche
      const f = await fichierNational(millesime, couche)
      if (!f) {
        logger.warn(
          `${millesime} / ${couche} : pas d'agrégat national ` +
            `(stratégie ${strategiePour(millesime)})`,
        )
        break
      }
      logger.info(`${f.key}\n  ${ko(f.size)} · ETag ${f.etag} · modifié ${f.lastModified}`)
      break
    }

    case 'migrer':
      await appliquerMigrations()
      break

    case 'referentiel':
      await chargerReferentiel()
      break

    default:
      logger.error(`commande inconnue : ${commande ?? '(aucune)'}`)
      logger.info('commandes : millesimes | catalogue <millesime> [couche] | migrer | referentiel')
      process.exitCode = 1
  }
}

main()
  .catch((e) => {
    logger.error(e instanceof Error ? e.message : String(e))
    process.exitCode = 1
  })
  .finally(fermer)
