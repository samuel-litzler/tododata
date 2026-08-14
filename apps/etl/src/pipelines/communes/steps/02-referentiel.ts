/**
 * Charge les référentiels administratifs de l'INSEE (départements, régions).
 *
 * Ils sont téléchargés puis insérés par COPY en flux : les fichiers font
 * quelques kilo-octets, mais on garde le même mécanisme que pour les gros
 * volumes plutôt que d'avoir deux chemins de chargement à maintenir.
 */
import { createReadStream } from 'node:fs'
import { mkdir, stat, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { pipeline } from 'node:stream/promises'
import { from as copyFrom } from 'pg-copy-streams'
import { pool } from '../../../_shared/db/pgClient.js'
import { logger } from '../../../_shared/observability/logger.js'
import { env } from '../../../env.js'

/** Page du COG au 1er janvier 2026 sur insee.fr. Change à chaque millésime annuel. */
const BASE = 'https://www.insee.fr/fr/statistiques/fichier/8740222'

const FICHIERS = [
  { nom: 'v_departement_2026.csv', table: 'insee.departement',
    colonnes: 'dep, reg, cheflieu, tncc, ncc, nccenr, libelle' },
  { nom: 'v_region_2026.csv', table: 'insee.region',
    colonnes: 'reg, cheflieu, tncc, ncc, nccenr, libelle' },
]

export async function chargerReferentiel(): Promise<void> {
  const dossier = join(env.dataDir, 'insee')
  await mkdir(dossier, { recursive: true })

  for (const f of FICHIERS) {
    const chemin = join(dossier, f.nom)

    // Cache local : ces fichiers ne bougent qu'une fois par an.
    const dejaLa = await stat(chemin).then((s) => s.size > 0).catch(() => false)
    if (!dejaLa) {
      logger.info(`téléchargement ${f.nom}`)
      const r = await fetch(`${BASE}/${f.nom}`)
      if (!r.ok) throw new Error(`${f.nom} : HTTP ${r.status}`)
      await writeFile(chemin, Buffer.from(await r.arrayBuffer()))
    }

    const client = await pool.connect()
    try {
      await client.query(`TRUNCATE ${f.table}`)
      // FORCE_NULL sur toutes les colonnes : l'INSEE écrit les valeurs absentes
      // en chaîne vide ENTRE GUILLEMETS, que `NULL ''` seul ne reconnaît pas.
      const flux = client.query(
        copyFrom(
          `COPY ${f.table} (${f.colonnes}) FROM STDIN
           WITH (FORMAT csv, HEADER true, NULL '', FORCE_NULL (${f.colonnes}))`,
        ),
      )
      await pipeline(createReadStream(chemin), flux)
      const { rows } = await client.query(`SELECT count(*)::int AS n FROM ${f.table}`)
      logger.info(`${f.table} : ${rows[0].n} lignes`)
    } finally {
      client.release()
    }
  }
}
