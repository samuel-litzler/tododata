/**
 * Applique les scripts SQL du pipeline communes, dans l'ordre de leur préfixe.
 *
 * Les scripts sont écrits pour être rejouables : ils recréent leurs tables
 * dérivées (DROP puis CREATE). On garde donc un journal des applications à
 * titre d'audit, mais on ne s'en sert pas pour sauter des scripts — c'est
 * volontaire, un run doit pouvoir reconstruire l'aval de bout en bout.
 */
import { readdir, readFile } from 'node:fs/promises'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { pool } from '../../../_shared/db/pgClient.js'
import { logger } from '../../../_shared/observability/logger.js'

const DOSSIER_SQL = resolve(dirname(fileURLToPath(import.meta.url)), '..', 'sql')

/** Scripts d'export : ils écrivent un fichier côté serveur, pas des tables. */
const EXPORTS = /^0[34]0-/

export async function appliquerMigrations(): Promise<void> {
  await pool.query(`
    CREATE SCHEMA IF NOT EXISTS qa;
    CREATE TABLE IF NOT EXISTS qa.migration (
      fichier    text PRIMARY KEY,
      applique_le timestamptz NOT NULL DEFAULT now(),
      duree_ms   integer
    );
  `)

  const fichiers = (await readdir(DOSSIER_SQL))
    .filter((f) => f.endsWith('.sql') && !EXPORTS.test(f))
    .sort()

  for (const fichier of fichiers) {
    const sql = await readFile(join(DOSSIER_SQL, fichier), 'utf8')
    // Les scripts contiennent des méta-commandes psql (\echo, \set) que le
    // protocole Postgres ne connaît pas : on les retire avant exécution.
    const nettoye = sql
      .split('\n')
      .filter((l) => !/^\s*\\/.test(l))
      .join('\n')

    const debut = Date.now()
    logger.info(`→ ${fichier}`)
    await pool.query(nettoye)
    const duree = Date.now() - debut

    await pool.query(
      `INSERT INTO qa.migration (fichier, duree_ms) VALUES ($1, $2)
       ON CONFLICT (fichier) DO UPDATE SET applique_le = now(), duree_ms = $2`,
      [fichier, duree],
    )
    logger.info(`  ${fichier} appliqué en ${(duree / 1000).toFixed(1)} s`)
  }

  logger.info(`${fichiers.length} script(s) appliqué(s)`)
}
