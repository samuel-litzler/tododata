/**
 * Contrat des réponses serveur.
 *
 * Ces types sont déclarés explicitement plutôt que déduits des handlers : avec
 * une URL dynamique (`useFetch(() => '/api/communes/' + code)`), Nuxt ne peut
 * pas choisir entre les routes qui matchent et infère leur union, ce qui rend
 * chaque accès de propriété invalide côté template.
 */

export type NatureTerritoire = 'noyau' | 'absorbee' | 'quartier'

export interface Territoire {
  prefixe: string
  /** Renseigné par le cadastre uniquement pour une partie des fusions. */
  ancienne: string | null
  nom_insee: string | null
  nom_cadastre: string | null
  nature: NatureTerritoire
  /** Code reconstitué (département + préfixe), null si ce n'est pas un code commune. */
  code: string | null
  fin_insee: string | null
  fusion_le: string | null
  km2: string | number | null
  geometrie: { type: string; coordinates: number[][][] | number[][][][] } | null
}

export interface PresenceMillesime {
  millesime: string
  present: boolean
  /** 'observee' | 'comblee' | 'absente' */
  origine: string
  nom: string | null
}

export interface MouvementInsee {
  mod: string
  date: string
  com_av: string
  libelle_av: string
  typecom_av: string
  com_ap: string
  libelle_ap: string
  typecom_ap: string
  sens: 'entrant' | 'sortant' | 'interne'
}

export interface PeriodeCog {
  libelle: string
  debut: string
  fin: string | null
}

export interface Anomalie {
  regle: string
  niveau: string
  millesime: string | null
  detail: Record<string, unknown> | null
}

export interface FicheCommune {
  identite: {
    code: string
    nom_cog: string | null
    departement: string | null
    nom_cadastre: string | null
    /** Non nul si le code est un arrondissement municipal : porte le code de la commune. */
    arm_parent: string | null
  }
  periodes: PeriodeCog[]
  presence: PresenceMillesime[]
  mouvements: MouvementInsee[]
  territoires: Territoire[]
  anomalies: Anomalie[]
}

export interface ResultatRecherche {
  code: string
  nom: string
  absorbees: number
}

export interface Stats {
  socle: {
    millesimes: number
    observations: string
    codes: number
    du: string
    au: string
  }
  evenements: { evenement: string; n: number }[]
  retard: { median: number; p90: number; n: number } | null
  couverture: { millesime: string; cadastre: number; insee: number }[]
  anomalies: { regle: string; niveau: string; n: number }[]
}

/** Réponse de /api/communes/[code]/resume — sans géométrie, pour le volet latéral. */
export interface ResumeCommune {
  identite: {
    code: string
    nom: string
    departement: string
    km2: string | number | null
    nb_absorbees: number
    millesimes_vus: number
    millesimes_combles: number
    millesimes_total: number
  }
  periodes: PeriodeCog[]
  absorbees: {
    code: string
    prefixe: string
    ancienne: string | null
    km2: string | number | null
    nom: string
    fin: string | null
    fusion_le: string | null
  }[]
  mouvements: {
    mod: string
    date: string
    com_av: string
    libelle_av: string
    com_ap: string
    libelle_ap: string
    sens: 'entrant' | 'sortant'
  }[]
  presence: { millesime: string; present: boolean; origine: string }[]
}

/** Réponse de /api/disparues/[code] — une commune qui n'existe plus. */
export interface DisparueResume {
  code: string
  nom: string
  encore_vivante: boolean
  periodes: PeriodeCog[]
  territoire: {
    absorbante_code: string
    absorbante_nom: string
    departement: string
    prefixe: string
    km2: string | number
    geometrie: { type: string; coordinates: number[][][] | number[][][][] } | null
  } | null
  contexte_geometrie: { type: string; coordinates: number[][][] | number[][][][] } | null
  mouvements: {
    mod: string
    date: string
    com_av: string
    libelle_av: string
    com_ap: string
    libelle_ap: string
    sens: string
  }[]
  soeurs: { code: string; nom: string; fin: string | null }[]
}
