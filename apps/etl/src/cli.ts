/**
 * Point d'entrée de l'ETL.
 *
 *   pnpm etl millesimes                      liste les millésimes publiés
 *   pnpm etl catalogue <millesime> [couche]  résout le fichier source et sa taille
 *   pnpm etl migrer                          applique les scripts SQL du pipeline communes
 *   pnpm etl referentiel                     charge les départements et régions de l'INSEE
 *   pnpm etl parcelles:migrer                pose le modèle parcelles (à faire avant)
 *   pnpm etl parcelles <dep>                 ingère les parcelles d'un département
 *   pnpm etl parcelles:france [n] [deps...]  ingère tous les départements, n en parallèle
 *   pnpm etl parcelles:synthese [dep]        reconstruit fiches et événements (à faire après)
 *   pnpm etl parcelles:rapport [dep]         restitue les contrôles du pipeline parcelles
 *   pnpm etl dvf:migrer                      pose le modèle DVF (à faire avant)
 *   pnpm etl dvf <livraison> [dep]           distille une livraison, ex : dvf 202504
 *   pnpm etl dvf:historique [dep]            distille les onze livraisons, dans l'ordre
 *   pnpm etl dvf:synthese                    reconstruit mutations et événements
 *   pnpm etl dvf:rapport                     restitue les contrôles du pipeline DVF
 *
 * Chaque commande est idempotente : la relancer ne doit rien casser.
 */
import { listerMillesimes, fichierNational, strategiePour, type Couche } from './_shared/acquisition/cadastreCatalog.js'
import { appliquerMigrations } from './pipelines/communes/steps/01-migrer.js'
import { chargerReferentiel } from './pipelines/communes/steps/02-referentiel.js'
import { migrerParcelles, synthetiserParcelles } from './pipelines/parcelles/steps/09-migrer.js'
import { ingererParcelles } from './pipelines/parcelles/steps/10-ingerer.js'
import { ingererFrance } from './pipelines/parcelles/steps/11-france.js'
import { rapportParcelles } from './pipelines/parcelles/steps/20-rapport.js'
import { migrerDvf, synthetiserDvf } from './pipelines/dvf/steps/30-migrer.js'
import { ingererLivraison, ingererHistorique } from './pipelines/dvf/steps/31-ingerer.js'
import { rapportDvf } from './pipelines/dvf/steps/32-rapport.js'
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

    case 'parcelles:migrer':
      await migrerParcelles()
      break

    case 'parcelles': {
      const dep = args[0]
      if (!dep) throw new Error('usage : parcelles <departement>, ex : parcelles 57')
      await ingererParcelles(dep)
      break
    }

    case 'parcelles:france': {
      const concurrence = Number(args[0]) || 3
      const deps = args.slice(1).filter((a) => /^[0-9AB]{2,3}$/i.test(a)).map((d) => d.toUpperCase())
      await ingererFrance(concurrence, deps.length ? deps : undefined)
      break
    }

    case 'parcelles:synthese':
      await synthetiserParcelles(args[0]?.toUpperCase())
      break

    case 'parcelles:rapport':
      await rapportParcelles(args[0])
      break

    case 'dvf:migrer':
      await migrerDvf()
      break

    case 'dvf': {
      const pub = args[0]
      if (!pub || !/^\d{6}$/.test(pub)) throw new Error('usage : dvf <livraison>, ex : dvf 202504')
      await ingererLivraison(pub, { departement: args[1], forcer: args.includes('--forcer') })
      break
    }

    case 'dvf:historique':
      await ingererHistorique({
        departement: args.find((a) => /^[0-9AB]{2,3}$/i.test(a))?.toUpperCase(),
        forcer: args.includes('--forcer'),
      })
      break

    case 'dvf:synthese':
      await synthetiserDvf()
      break

    case 'dvf:rapport':
      await rapportDvf()
      break

    default:
      logger.error(`commande inconnue : ${commande ?? '(aucune)'}`)
      logger.info(
        'commandes : millesimes | catalogue <millesime> [couche] | migrer | referentiel | ' +
          'parcelles:migrer | parcelles <dep> | parcelles:france [n] | parcelles:synthese | ' +
          'parcelles:rapport [dep]',
      )
      process.exitCode = 1
  }
}

main()
  .catch((e) => {
    logger.error(e instanceof Error ? e.message : String(e))
    process.exitCode = 1
  })
  .finally(fermer)
