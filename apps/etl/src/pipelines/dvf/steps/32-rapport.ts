/**
 * Restitution des contrôles du pipeline DVF.
 *
 * Comme pour les parcelles : rien n'est calculé ici. Le rapport lit les tables
 * produites par 420-qa.sql, pour qu'aucune divergence ne puisse s'installer
 * entre ce qu'on contrôle et ce qu'on montre.
 */
import { pool } from '../../../_shared/db/pgClient.js'
import { logger } from '../../../_shared/observability/logger.js'

const n = (v: number | string | null) =>
  v == null ? '—' : Number(v).toLocaleString('fr-FR')

export async function rapportDvf(): Promise<void> {
  const { rows: livraisons } = await pool.query(
    `SELECT to_char(publication,'YYYY-MM') AS pub,
            to_char(debut,'YYYY-MM-DD') AS debut, to_char(fin,'YYYY-MM-DD') AS fin,
            n_fichiers, n_lignes, n_ouvertures, n_fermetures, duree_s
       FROM qa.dvf_livraison ORDER BY publication`,
  )

  if (livraisons.length === 0) {
    logger.warn("aucune livraison distillée — lancer `dvf:historique` puis `dvf:synthese`")
    return
  }

  logger.info(`${livraisons.length} livraisons distillées`)
  logger.info('  livraison  couverture               fich.     lignes  ouvertures   retraits')
  for (const l of livraisons) {
    logger.info(
      `  ${l.pub}    ${l.debut} → ${l.fin}  ${String(l.n_fichiers).padStart(5)}  ` +
        `${n(l.n_lignes).padStart(9)}  ${n(l.n_ouvertures).padStart(10)}  ` +
        `${n(l.n_fermetures).padStart(9)}`,
    )
  }

  // --- Le contrôle central ------------------------------------------------
  // Une année passée bouge-t-elle ? Une ligne constante répondrait « non » ;
  // toute variation est une révision que la DGFiP ne signale nulle part.
  // Seules les livraisons COUVRANT l'année entière sont comparables : celles
  // d'octobre n'en portent qu'un semestre, et les mêler ferait passer un
  // demi-fichier pour une révision massive.
  const { rows: annees } = await pool.query(
    `SELECT annee,
            array_agg(n_lignes ORDER BY publication)     AS suite,
            min(n_lignes) AS mini, max(n_lignes) AS maxi,
            count(*)      AS n_livraisons
       FROM qa.dvf_annee_par_livraison
      WHERE complete
      GROUP BY annee HAVING count(*) > 1 ORDER BY annee`,
  )

  logger.info('')
  logger.info('révision des années passées — livraisons couvrant l’année entière')
  for (const a of annees) {
    const bouge = Number(a.maxi) - Number(a.mini)
    logger.info(
      `  ${a.annee}  ${String(a.n_livraisons).padStart(2)} livraisons  ` +
        `${n(a.mini).padStart(9)} → ${n(a.maxi).padStart(9)}  ` +
        `écart ${n(bouge).padStart(6)}  ${(a.suite as number[]).join(' · ')}`,
    )
  }

  // --- Ventes avec et sans lots -------------------------------------------
  const { rows: lots } = await pool.query(
    `SELECT nature, avec_lots, n_mutations, n_parcelles, valeur_mediane
       FROM qa.dvf_lots ORDER BY n_mutations DESC LIMIT 8`,
  )
  if (lots.length) {
    logger.info('')
    logger.info('mutations par nature et présence de lots')
    for (const l of lots) {
      logger.info(
        `  ${String(l.nature).padEnd(30)} ${l.avec_lots ? 'avec lots' : 'hors lots'}  ` +
          `${n(l.n_mutations).padStart(8)} mutations  ` +
          `médiane ${n(l.valeur_mediane).padStart(9)} €`,
      )
    }
  }

  // --- Rattachement au cadastre -------------------------------------------
  const { rows: rat } = await pool.query(
    `SELECT situation, n_couples, n_parcelles FROM qa.dvf_rattachement
      ORDER BY n_couples DESC`,
  )
  if (rat.length) {
    logger.info('')
    logger.info('rattachement des mutations aux parcelles')
    for (const r of rat) {
      logger.info(
        `  ${String(r.situation).padEnd(30)} ${n(r.n_couples).padStart(9)} couples  ` +
          `${n(r.n_parcelles).padStart(9)} parcelles`,
      )
    }
  }
}
