/**
 * Ingestion d'une livraison DVF.
 *
 * Les onze livraisons ne se ressemblent pas : .txt en 2019, .txt.gz ensuite,
 * .txt.zip depuis fin 2024. On lit donc l'extension à l'exécution, jamais
 * l'année — c'est la leçon des personnes morales, où deviner d'après le
 * millésime avait produit des URL introuvables et un encodage faux.
 *
 * Le décodage et le filtrage restent hors de Node : un `awk` dans un tube
 * traite quinze gigaoctets sans que le processus ETL n'ait à voir passer une
 * seule ligne. Node ne fait qu'ouvrir le COPY et attendre.
 */
import { spawn } from 'node:child_process'
import { readdir } from 'node:fs/promises'
import { join } from 'node:path'
import { from as copyFrom } from 'pg-copy-streams'
import { pipeline } from 'node:stream/promises'
import { pool } from '../../../_shared/db/pgClient.js'
import { logger } from '../../../_shared/observability/logger.js'

export const RACINE = process.env.DVF_SOURCE ?? '/home/bbw/data/nexus-dvf/source'

interface Options {
  /** Restreint à un département — utile pour valider sans charger la France. */
  departement?: string
  /** Recharge une livraison déjà distillée. */
  forcer?: boolean
}

/** Commande shell qui décomprime un fichier, quel que soit son emballage. */
function lecteur(chemin: string): string {
  const q = `'${chemin.replace(/'/g, `'\\''`)}'`
  if (chemin.endsWith('.gz')) return `gzip -dc ${q}`
  if (chemin.endsWith('.zip')) return `unzip -p ${q}`
  return `cat ${q}`
}

/**
 * Les fichiers d'une livraison, dans l'ordre chronologique.
 *
 * Une livraison peut contenir À LA FOIS l'année pleine et son second semestre :
 * 202110 livre `2016-s2` ET `2016`. Charger les deux dupliquerait tout le second
 * semestre et fausserait le rang d'occurrence, qui départage les doublons
 * légitimes. L'année pleine prime donc sur ses tranches semestrielles.
 */
export async function fichiersDe(dossier: string): Promise<string[]> {
  const noms = (await readdir(dossier)).filter((f) => f.startsWith('valeursfoncieres-'))

  const annees = new Set<string>()
  for (const n of noms) {
    const m = n.match(/^valeursfoncieres-(\d{4})\.txt/)
    if (m?.[1]) annees.add(m[1])
  }

  return noms
    .filter((n) => {
      const m = n.match(/^valeursfoncieres-(\d{4})(-s\d)?\.txt/)
      if (!m?.[1]) return false
      return !m[2] || !annees.has(m[1]) // une tranche n'est gardée que sans son année pleine
    })
    .sort()
}

export async function ingererLivraison(pub: string, options: Options = {}): Promise<void> {
  const publication = `${pub.slice(0, 4)}-${pub.slice(4, 6)}-01`
  const debut = Date.now()

  const { rows: deja } = await pool.query(
    'SELECT 1 FROM dvf.publication WHERE publication = $1',
    [publication],
  )
  if (deja.length && !options.forcer) {
    logger.info(`${pub} déjà distillée, ignorée`)
    return
  }

  const dossier = join(RACINE, pub)
  const fichiers = await fichiersDe(dossier)
  if (!fichiers.length) throw new Error(`${pub} : aucun fichier valeursfoncieres-*`)

  // Un schéma de travail par livraison : plusieurs livraisons peuvent être
  // chargées de front sans que leurs tables de préparation se confondent.
  const schema = `travail_dvf_${pub}`
  const client = await pool.connect()
  try {
    await client.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`)
    await client.query(`CREATE SCHEMA ${schema}`)
    await client.query(
      `CREATE TABLE ${schema}.dvf_stage (LIKE raw.dvf_stage INCLUDING DEFAULTS)`,
    )

    // Un seul tube pour toute la livraison : le compteur `ordre` reste ainsi
    // continu d'un fichier à l'autre. Cet ordre n'est pas décoratif — c'est la
    // contiguïté des lignes qui permet de reconstituer les mutations, le champ
    // qui identifierait l'acte étant blanchi dans l'open data.
    const lecture = fichiers.map((f) => lecteur(join(dossier, f))).join('; ')
    // Un motif awk, pas une condition à recoller : `$19 == "01" && { … }` est
    // une erreur de syntaxe, et awk sort alors sans rien écrire.
    const filtre = options.departement ? `$19 == "${options.departement}" ` : ''
    // Chaque fichier porte son propre en-tête : concaténés, ils réapparaissent
    // en plein milieu du flux.
    //
    // On les reconnaît à la FORME de leur colonne date, pas à un libellé. La
    // première version testait `$1 == "Code service CH"` — et ce libellé est
    // devenu « Identifiant de document » à la livraison d'avril 2023. L'en-tête
    // passait alors pour une donnée, et la distillation de 17 200 937 lignes
    // tombait sur `invalid value "Da" for "DD"`. Le filtre départemental des
    // essais masquait le défaut : un en-tête ne porte pas non plus de code
    // département.
    //
    // Ce qui est écarté est COMPTÉ et remonté : un fichier dont toutes les lignes
    // seraient rejetées ne doit pas passer pour un chargement réussi.
    const estUneDate = '$9 ~ /^[0-9][0-9]\\/[0-9][0-9]\\/[0-9][0-9][0-9][0-9]$/'
    const awk =
      `awk -F'|' '${estUneDate} { ${filtre ? `if (${filtre.trim()}) ` : ''}` +
      `{ printf "%d|%s\\n", ++n, $0 }; next } { ecartees++ } ` +
      `END { if (ecartees > 0) print "lignes écartées (en-tête ou date illisible) : " ecartees > "/dev/stderr" }'`

    logger.info(`${pub} : ${fichiers.length} fichier(s)${options.departement ? ` · dép. ${options.departement}` : ''}`)

    const flux = client.query(
      copyFrom(
        `COPY ${schema}.dvf_stage FROM STDIN WITH (FORMAT csv, DELIMITER '|', QUOTE E'\\b', NULL '')`,
      ),
    )
    // QUOTE sur un caractère absent du fichier : DVF n'échappe rien, et le
    // guillemet par défaut ferait avaler des lignes entières au premier libellé
    // de voie contenant un pouce.
    const sh = spawn('sh', ['-c', `{ ${lecture} ; } | ${awk}`], {
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    let erreurs = ''
    sh.stderr.on('data', (d) => (erreurs += d.toString().slice(0, 2000)))

    // La promesse est armée AVANT d'attendre le tube. Un shell qui échoue se
    // termine avant que le tube ne se dénoue : brancher l'écouteur après, c'est
    // attendre un événement déjà passé — le process reste suspendu, sans erreur
    // et sans fin.
    const fin = new Promise<number>((res) => sh.on('close', res))
    await pipeline(sh.stdout, flux)
    const code = await fin
    if (code !== 0) throw new Error(`lecture de la livraison en échec (${code}) : ${erreurs.trim()}`)

    // Un shell peut sortir en 0 sans avoir rien produit — un motif awk erroné,
    // un filtre qui ne retient rien. On le dit ici plutôt que de laisser la
    // distillation conclure sur une livraison vide.
    const { rows: [{ n }] } = await client.query<{ n: string }>(
      `SELECT count(*)::text AS n FROM ${schema}.dvf_stage`,
    )
    if (Number(n) === 0) {
      throw new Error(
        `${pub} : aucune ligne chargée${options.departement ? ` pour le dép. ${options.departement}` : ''}` +
          (erreurs.trim() ? ` — ${erreurs.trim()}` : ''),
      )
    }

    const { rows } = await client.query<{
      n_lignes: string; n_ouvertures: string; n_fermetures: string
    }>('SELECT * FROM dvf.distiller($1::date, $2)', [publication, schema])

    // Ce qu'awk a écarté : un en-tête par fichier en régime normal. Toute autre
    // valeur mérite un regard — c'est le signe d'un format qui bouge.
    if (erreurs.trim()) logger.info(`${pub} : ${erreurs.trim()}`)

    const r = rows[0]!
    await client.query(
      `UPDATE dvf.publication SET n_fichiers = $2, duree_ms = $3 WHERE publication = $1`,
      [publication, fichiers.length, Date.now() - debut],
    )
    logger.info(
      `${pub} : ${Number(r.n_lignes).toLocaleString('fr')} lignes · ` +
        `+${Number(r.n_ouvertures).toLocaleString('fr')} ouvertures · ` +
        `−${Number(r.n_fermetures).toLocaleString('fr')} fermetures · ` +
        `${((Date.now() - debut) / 1000).toFixed(0)} s`,
    )
  } finally {
    await client.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`).catch(() => {})
    client.release()
  }
}

/** Toutes les livraisons présentes sur le disque, dans l'ordre chronologique. */
export async function ingererHistorique(options: Options = {}): Promise<void> {
  const pubs = (await readdir(RACINE)).filter((d) => /^\d{6}$/.test(d)).sort()
  logger.info(`${pubs.length} livraisons à distiller : ${pubs.join(', ')}`)
  // Strictement séquentiel : chaque livraison se compare à l'état laissé par la
  // précédente. Les paralléliser produirait des ouvertures et des fermetures
  // dans le désordre, donc un historique faux.
  for (const p of pubs) await ingererLivraison(p, options)
}
