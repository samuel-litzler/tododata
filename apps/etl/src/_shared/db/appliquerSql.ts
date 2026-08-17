/**
 * Applique les scripts SQL d'un pipeline, dans l'ordre de leur préfixe numérique.
 *
 * Les scripts sont écrits pour être rejouables : ils recréent leurs objets
 * dérivés (CREATE OR REPLACE, DROP puis CREATE, CREATE IF NOT EXISTS). On garde
 * un journal des applications à titre d'audit, mais on ne s'en sert pas pour
 * sauter des scripts — c'est volontaire, un run doit pouvoir reconstruire l'aval
 * de bout en bout.
 */
import { readdir, readFile } from 'node:fs/promises'
import { join } from 'node:path'
import { pool } from './pgClient.js'
import { logger } from '../observability/logger.js'

interface Options {
  /** Scripts à ne pas exécuter ici (exports vers fichiers, etc.). */
  ignorer?: RegExp
}

export async function appliquerSql(dossier: string, options: Options = {}): Promise<void> {
  await pool.query(`
    CREATE SCHEMA IF NOT EXISTS qa;
    CREATE TABLE IF NOT EXISTS qa.migration (
      fichier    text PRIMARY KEY,
      applique_le timestamptz NOT NULL DEFAULT now(),
      duree_ms   integer
    );
  `)

  const fichiers = (await readdir(dossier))
    .filter((f) => f.endsWith('.sql') && !options.ignorer?.test(f))
    .sort()

  for (const fichier of fichiers) {
    const sql = await readFile(join(dossier, fichier), 'utf8')
    // Les scripts peuvent contenir des méta-commandes psql (\echo, \set) que le
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
