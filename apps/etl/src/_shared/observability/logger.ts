import { pino } from 'pino'
import { env } from '../../env.js'

/**
 * Un run d'ingestion dure des heures. Les logs doivent rester lisibles en
 * direct au terminal, et exploitables après coup — d'où pino-pretty en dev et
 * du JSON structuré dès qu'on redirige vers un fichier.
 */
export const logger = pino({
  level: env.logLevel,
  transport: process.stdout.isTTY
    ? { target: 'pino-pretty', options: { translateTime: 'HH:MM:ss', ignore: 'pid,hostname' } }
    : undefined,
})

export type Logger = typeof logger
