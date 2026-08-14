import { Pool } from 'pg'

/**
 * Un pool unique pour tout le process Nitro. En dev, le hot-reload réévalue les
 * modules : sans ce cache sur globalThis on accumulerait un pool par rechargement
 * jusqu'à saturer les connexions Postgres.
 */
declare global {
  // eslint-disable-next-line no-var
  var __nexusPool: Pool | undefined
}

export function db(): Pool {
  if (!globalThis.__nexusPool) {
    const c = useRuntimeConfig()
    globalThis.__nexusPool = new Pool({
      host: c.dbHost,
      port: Number(c.dbPort),
      user: c.dbUser,
      password: c.dbPassword,
      database: c.dbName,
      max: 8,
    })
  }
  return globalThis.__nexusPool
}

/** Raccourci : exécute une requête et renvoie les lignes typées. */
export async function q<T = Record<string, unknown>>(
  sql: string,
  params: unknown[] = [],
): Promise<T[]> {
  const res = await db().query(sql, params)
  return res.rows as T[]
}
