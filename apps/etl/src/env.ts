/**
 * Configuration de l'ETL.
 *
 * Pas de Zod : la stack reste Node + TS + le strict nécessaire. Une poignée
 * d'accesseurs qui lèvent sur valeur invalide suffit à cadrer.
 */
import { resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { readFileSync, existsSync } from 'node:fs'

const ici = dirname(fileURLToPath(import.meta.url))

// Chargement minimal du .env : apps/etl/.env puis la racine du repo.
for (const chemin of [resolve(ici, '..', '.env'), resolve(ici, '..', '..', '..', '.env')]) {
  if (!existsSync(chemin)) continue
  for (const ligne of readFileSync(chemin, 'utf8').split('\n')) {
    const m = ligne.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/)
    if (m && process.env[m[1]!] === undefined) {
      process.env[m[1]!] = m[2]!.replace(/^["']|["']$/g, '')
    }
  }
}

const txt = (cle: string, defaut: string) => process.env[cle] ?? defaut
const num = (cle: string, defaut: number) => {
  const brut = process.env[cle]
  if (!brut) return defaut
  const n = Number(brut)
  if (Number.isNaN(n)) throw new Error(`${cle} n'est pas un nombre : ${brut}`)
  return n
}

export const env = {
  pg: {
    host: txt('DB_HOST', 'localhost'),
    // 5432 = Postgres natif de l'hôte, 5433 = todoride. Nous sommes sur 5434.
    port: num('DB_PORT', 5434),
    user: txt('DB_USER', 'nexus'),
    password: txt('DB_PASSWORD', 'nexus_dev'),
    database: txt('DB_NAME', 'nexus'),
  },
  /** Cache des fichiers téléchargés. Partagé avec le container via /work. */
  dataDir: txt('DATA_DIR', '/home/bbw/data/nexus-cadastre/work'),
  logLevel: txt('LOG_LEVEL', 'info'),
}
