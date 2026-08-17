/**
 * Scripts SQL du pipeline DVF, en deux temps — même découpage que les parcelles.
 *
 * 3xx = modèle et distillation, à poser AVANT toute ingestion.
 * 4xx = couche dérivée (mutations, événements), reconstruite APRÈS.
 */
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { appliquerSql } from '../../../_shared/db/appliquerSql.js'

const DOSSIER_SQL = resolve(dirname(fileURLToPath(import.meta.url)), '..', 'sql')

const DERIVE = /^[4-9]\d\d-/

export async function migrerDvf(): Promise<void> {
  await appliquerSql(DOSSIER_SQL, { ignorer: DERIVE })
}

export async function synthetiserDvf(): Promise<void> {
  await appliquerSql(DOSSIER_SQL, { ignorer: /^3\d\d-/ })
}
