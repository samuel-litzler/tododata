/**
 * Scripts SQL du pipeline parcelles, en deux temps.
 *
 * Le découpage n'est pas cosmétique : les scripts 1xx définissent le modèle et
 * doivent exister AVANT l'ingestion, ceux de la synthèse dérivent de données
 * déjà ingérées et doivent tourner APRÈS. Les appliquer tous d'un bloc en amont
 * reconstruirait la synthèse sur l'état précédent — c'est-à-dire sur rien, au
 * premier run.
 */
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { appliquerSql } from '../../../_shared/db/appliquerSql.js'

const DOSSIER_SQL = resolve(dirname(fileURLToPath(import.meta.url)), '..', 'sql')

/** 1xx = modèle et ingestion. 2xx = couche dérivée, reconstruite après coup. */
const DERIVE = /^[2-9]\d\d-/

export async function migrerParcelles(): Promise<void> {
  await appliquerSql(DOSSIER_SQL, { ignorer: DERIVE })
}

export async function synthetiserParcelles(departement?: string): Promise<void> {
  if (!departement) {
    await appliquerSql(DOSSIER_SQL, { ignorer: /^1\d\d-/ })
    return
  }

  // Reconstruction bornée à un département. 200-synthese.sql refond les tables
  // en entier : rejouer 67 M de versions pour en rafraîchir 2 M coûte des heures
  // et concurrence l'ingestion qui tourne encore. 220 pose la fonction qui fait
  // le même travail en remplaçant les lignes du seul département visé.
  const { pool } = await import('../../../_shared/db/pgClient.js')
  const { logger } = await import('../../../_shared/observability/logger.js')
  await appliquerSql(DOSSIER_SQL, { ignorer: /^(1\d\d-|200-|210-|3\d\d-)/ })

  const debut = Date.now()
  const { rows } = await pool.query<{
    n_parcelles: string; n_evenements: string; n_filiations: string
  }>('SELECT * FROM parc.synthetiser_departement($1)', [departement])

  const r = rows[0]!
  logger.info(
    `${departement} : ${Number(r.n_parcelles).toLocaleString('fr')} parcelles · ` +
      `${Number(r.n_evenements).toLocaleString('fr')} événements · ` +
      `${Number(r.n_filiations).toLocaleString('fr')} filiations · ` +
      `${((Date.now() - debut) / 1000).toFixed(0)} s`,
  )
}
