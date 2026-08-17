/**
 * Applique les scripts SQL du pipeline communes.
 */
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { appliquerSql } from '../../../_shared/db/appliquerSql.js'

const DOSSIER_SQL = resolve(dirname(fileURLToPath(import.meta.url)), '..', 'sql')

/** Scripts d'export : ils écrivent un fichier côté serveur, pas des tables. */
const EXPORTS = /^0[34]0-/

export async function appliquerMigrations(): Promise<void> {
  await appliquerSql(DOSSIER_SQL, { ignorer: EXPORTS })
}
