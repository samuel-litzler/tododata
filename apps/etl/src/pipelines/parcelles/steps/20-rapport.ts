/**
 * Restitution des contrôles du pipeline parcelles.
 *
 * Lit les tables produites par 300-qa.sql et les met en forme. Rien n'est calculé
 * ici : le rapport doit pouvoir être rejoué sans rien recalculer, et surtout sans
 * qu'une divergence puisse apparaître entre ce qu'on contrôle et ce qu'on montre.
 */
import { pool } from '../../../_shared/db/pgClient.js'
import { logger } from '../../../_shared/observability/logger.js'

const n = (v: number | string | null) =>
  v == null ? '—' : Number(v).toLocaleString('fr-FR')
const pct = (v: number | string | null) =>
  v == null ? '—' : `${Number(v).toFixed(2)} %`

export async function rapportParcelles(departement?: string): Promise<void> {
  const filtre = departement ? 'WHERE departement = $1' : ''
  const args = departement ? [departement] : []

  // --- Les relevés --------------------------------------------------------
  const { rows: releves } = await pool.query(
    `SELECT to_char(millesime,'YYYY-MM-DD') AS millesime, format, n_parcelles,
            variation, n_ouvertures, n_disparitions, pct_mouvement, duree_s
       FROM qa.parcelles_releve ${filtre} ORDER BY millesime`,
    args,
  )

  if (releves.length === 0) {
    logger.warn('aucun relevé distillé — lancer `parcelles <dep>` puis `parcelles:synthese`')
    return
  }

  logger.info(`${releves.length} relevés distillés`)
  logger.info('  date        fmt      parcelles   variation   ouvertures  disparues  mouvement')
  for (const r of releves) {
    logger.info(
      `  ${r.millesime}  ${String(r.format).padEnd(7)}  ` +
        `${n(r.n_parcelles).padStart(9)}  ${n(r.variation).padStart(9)}  ` +
        `${n(r.n_ouvertures).padStart(10)}  ${n(r.n_disparitions).padStart(9)}  ` +
        `${pct(r.pct_mouvement).padStart(9)}`,
    )
  }

  // --- Le contrôle le plus parlant ----------------------------------------
  // Deux mesures indépendantes du même objet : le dessin et la déclaration.
  // Leur accord valide toute la chaîne géométrique d'un coup.
  const { rows: [surface] = [] } = await pool.query(
    `SELECT * FROM qa.parcelles_surface`,
  )
  if (surface) {
    logger.info('')
    logger.info('Géométrie confrontée à la contenance déclarée')
    logger.info(`  échantillon        ${n(surface.n)} parcelles`)
    logger.info(`  écart moyen        ${pct(surface.ecart_moyen * 100)}`)
    logger.info(`  écart médian       ${pct(surface.ecart_median * 100)}`)
    logger.info(`  95e centile        ${pct(surface.ecart_p95 * 100)}`)
    logger.info(`  au-delà de 10 %    ${n(surface.n_au_dela_10pct)}`)
    logger.info(`  au-delà de 50 %    ${n(surface.n_au_dela_50pct)}`)
  }

  // --- Le préfixe, confronté une seconde fois -----------------------------
  const { rows: [prefixe] = [] } = await pool.query(
    `SELECT count(*)::int AS n_prefixes,
            count(*) FILTER (WHERE insee_atteste)::int AS n_attestes,
            sum(n_parcelles)::bigint AS n_parcelles
       FROM qa.parcelles_prefixe`,
  )
  if (prefixe?.n_prefixes) {
    logger.info('')
    logger.info('Préfixes non-000 (trace des communes absorbées)')
    logger.info(`  préfixes distincts       ${n(prefixe.n_prefixes)}`)
    logger.info(
      `  dont code INSEE attesté  ${n(prefixe.n_attestes)} ` +
        `(${pct((prefixe.n_attestes / prefixe.n_prefixes) * 100)})`,
    )
    logger.info(`  parcelles concernées     ${n(prefixe.n_parcelles)}`)
  }

  // --- Filiation ----------------------------------------------------------
  const { rows: filiation } = await pool.query(
    `SELECT type, count(*)::int AS n,
            count(*) FILTER (WHERE certain)::int AS n_certains
       FROM parc.filiation GROUP BY type ORDER BY 2 DESC`,
  )
  if (filiation.length) {
    logger.info('')
    logger.info('Filiation entre parcelles')
    for (const f of filiation) {
      logger.info(
        `  ${String(f.type).padEnd(16)} ${n(f.n).padStart(8)}` +
          (f.n_certains ? `   dont ${n(f.n_certains)} constatés (empreinte identique)` : ''),
      )
    }
  }

  // --- Trous de présence --------------------------------------------------
  const { rows: [trous] = [] } = await pool.query(
    `SELECT count(*)::int AS n FROM qa.parcelles_trou`,
  )
  const { rows: [parcelles] = [] } = await pool.query(
    `SELECT count(*)::int AS n,
            count(*) FILTER (WHERE presente)::int AS presentes,
            count(*) FILTER (WHERE anterieure_a_nos_releves)::int AS anterieures
       FROM parc.parcelle`,
  )
  if (parcelles) {
    logger.info('')
    logger.info('Population')
    logger.info(`  parcelles jamais observées   ${n(parcelles.n)}`)
    logger.info(`  encore présentes             ${n(parcelles.presentes)}`)
    logger.info(
      `  créées avant notre 1er relevé ${n(parcelles.anterieures)} ` +
        `(${pct((parcelles.anterieures / parcelles.n) * 100)})`,
    )
    logger.info(`  disparues puis revenues      ${n(trous?.n ?? 0)}`)
  }
}
