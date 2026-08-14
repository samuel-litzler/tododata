import { Pool, type PoolClient } from 'pg'
import { env } from '../../env.js'

/**
 * Un seul pool pour tout le process. L'ETL est mono-worker : la concurrence
 * utile se situe dans Postgres (workers parallèles pour les index), pas dans le
 * nombre de connexions.
 */
export const pool = new Pool({
  ...env.pg,
  max: 4,
  // Les CREATE INDEX GIST et les ST_Union départementaux dépassent la minute.
  statement_timeout: 0,
})

/** Exécute une fonction dans une transaction, avec rollback sur erreur. */
export async function enTransaction<T>(fn: (c: PoolClient) => Promise<T>): Promise<T> {
  const client = await pool.connect()
  try {
    await client.query('BEGIN')
    const res = await fn(client)
    await client.query('COMMIT')
    return res
  } catch (e) {
    await client.query('ROLLBACK')
    throw e
  } finally {
    client.release()
  }
}

export async function fermer(): Promise<void> {
  await pool.end()
}
