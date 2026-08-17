<script setup lang="ts">
/**
 * Fiche d'une parcelle : son identité, sa vie, et sa parenté.
 *
 * URL au singulier — /parcelle/<id> — là où /parcelles/<commune> désigne la
 * collection d'une commune. Ce n'est pas une coquetterie : les deux segments
 * porteraient sinon le même paramètre dynamique et il faudrait distinguer un
 * code commune d'un identifiant de parcelle à la longueur de la chaîne, ce qui
 * est exactement le genre de règle implicite qui casse un jour.
 */
definePageMeta({ key: (route) => route.fullPath })

const route = useRoute()
const id = computed(() => String(route.params.id).toUpperCase())

interface Noeud {
  id: string
  commune: string
  prefixe: string
  section: string
  numero: string
  contenance: number | null
  surface_m2: number | null
  presente: boolean
  vu_premier: string
  vu_dernier: string
  geom: unknown
}

interface Reponse {
  parcelle: {
    id_parcelle: string
    commune: string
    prefixe: string
    section: string
    numero: string
    n_versions: number
    vu_premier: string
    vu_dernier: string
    presente: boolean
    apparition_observee: boolean
    cree_source: string | null
    maj_source: string | null
    anterieure_a_nos_releves: boolean
  }
  versions: {
    no_version: number
    contenance: number | null
    arpente: boolean | null
    surface_m2: number | null
    vu_debut: string
    vu_fin: string | null
  }[]
  evenements: { millesime: string; type: string; detail: string[] | null }[]
  ventes: {
    date_mutation: string
    nature: string
    valeur: number | null
    avec_lots: boolean
    types: string[]
    surface_bati: number | null
    surface_terrain: number | null
    n_prix: number
    retard_jours: number
    vu_debut: string
  }[]
  ventesHeritees: {
    date_mutation: string
    nature: string
    valeur: number | null
    avec_lots: boolean
    types: string[]
    surface_terrain: number | null
    herite_de: string
    filiation: string
    part: number | null
  }[]
  liens: {
    id_avant: string
    id_apres: string
    type: string
    part_avant: number | null
    part_apres: number | null
    certain: boolean
    millesime: string
    saut: number
  }[]
  noeuds: Noeud[]
  commune: string | null
  absorbee: { com: string; libelle: string; date_fin: string | null } | null
  communes: Record<string, string>
  tronque: boolean
  atteints: number
}

// Type explicite : l'URL dynamique empêche Nuxt de choisir parmi les routes qui
// matchent /api/parcelles/*, il en inférerait l'union.
const { data, error } = await useFetch<Reponse>(() => `/api/parcelles/${id.value}`)

const p = computed(() => data.value?.parcelle)
useHead({
  title: () =>
    p.value ? `Parcelle ${p.value.section} ${p.value.numero} — ${data.value?.commune ?? ''}` : id.value,
})

const surface = (m2: number | null | undefined) =>
  m2 == null ? '—' : m2 >= 10000 ? `${(m2 / 10000).toFixed(2)} ha` : `${Math.round(m2).toLocaleString('fr-FR')} m²`

const dateLisible = (iso: string | null) =>
  !iso ? '—' : new Date(iso).toLocaleDateString('fr-FR', { day: 'numeric', month: 'long', year: 'numeric' })

const LIBELLE_EVT: Record<string, string> = {
  apparition: 'Entre au cadastre',
  modification: 'Tracé modifié',
  disparition: 'Cesse d’exister',
  reapparition: 'Réapparaît après une absence',
}

/**
 * Chronologie enrichie de sa filiation.
 *
 * Un événement nu ne dit presque rien : « cesse d'exister le 1er janvier 2019 »
 * laisse le lecteur devant un trou, alors qu'on sait dans quelles parcelles le
 * terrain est parti et dans quelles proportions.
 *
 * Le libellé lui-même est recalculé, et c'est le point important : une parcelle
 * dont tout le terrain repart sous un autre numéro, à géométrie rigoureusement
 * identique, N'A PAS cessé d'exister. Écrire « cesse d'exister » sur le cas
 * Vionville — où c'est la commune qui a fusionné autour d'un terrain immobile —
 * était simplement faux.
 */
const chronologie = computed(() => {
  const d = data.value
  if (!d) return []
  const surfaceDe = (idp: string) => d.noeuds.find((n) => n.id === idp)?.surface_m2 ?? null

  return d.evenements.map((e) => {
    const sortants = d.liens.filter((l) => l.id_avant === id.value && l.millesime === e.millesime)
    const entrants = d.liens.filter((l) => l.id_apres === id.value && l.millesime === e.millesime)
    const parents = e.type === 'disparition' ? sortants : entrants
    const renumerotation = parents.length === 1 && parents[0]!.certain

    let titre = LIBELLE_EVT[e.type] ?? e.type
    if (e.type === 'disparition') {
      if (renumerotation) titre = 'Change de numéro'
      else if (sortants.length > 1) titre = 'Son terrain est redécoupé'
      else if (sortants.length === 1) titre = 'Absorbée par une autre parcelle'
    } else if (e.type === 'apparition' && entrants.length) {
      titre = renumerotation ? 'Reprend le numéro d’une parcelle antérieure' : 'Née d’un redécoupage'
    }

    // Le terrain part-il vers une autre commune ?
    const horsCommune = parents.filter(
      (l) =>
        (e.type === 'disparition' ? l.id_apres : l.id_avant).slice(0, 5) !== d.parcelle.commune,
    )

    return {
      ...e,
      titre,
      renumerotation,
      horsCommune,
      relations: parents.map((l) => {
        const autre = e.type === 'disparition' ? l.id_apres : l.id_avant
        const n = d.noeuds.find((x) => x.id === autre)
        return {
          id: autre,
          libelle: n ? `${n.section} ${n.numero}` : autre,
          commune: n?.commune ?? autre.slice(0, 5),
          surface: surfaceDe(autre),
          // Part du terrain de CETTE parcelle qui passe dans l'autre (ou en vient).
          part: e.type === 'disparition' ? l.part_avant : l.part_apres,
          certain: l.certain,
          type: l.type,
        }
      }),
    }
  })
})

// Liens DIRECTS de la parcelle consultée. Le graphe en montre bien davantage —
// tout son voisinage — mais le résumé en tête de section ne parle que d'elle.
const ascendants = computed(
  () => data.value?.liens.filter((l) => l.id_apres === id.value) ?? [],
)
const descendants = computed(
  () => data.value?.liens.filter((l) => l.id_avant === id.value) ?? [],
)

/**
 * Liens qui traversent une frontière communale. C'est l'événement le plus fort
 * que ce graphe puisse porter : le terrain n'a pas seulement changé de forme, il
 * a changé de commune — fusion, ou rectification de limite entre voisines.
 */
const changementsCommune = computed(() =>
  (data.value?.liens ?? []).filter((l) => l.id_avant.slice(0, 5) !== l.id_apres.slice(0, 5)),
)

const nomCommune = (code: string) => data.value?.communes?.[code] ?? code

/**
 * La chaîne des identifiants qui désignent LE MÊME terrain.
 *
 * Distinction essentielle, et c'est tout l'intérêt du drapeau `certain` : un lien
 * de renumérotation relie deux codes portant une géométrie rigoureusement
 * identique — c'est la même parcelle sous un autre numéro, typiquement parce que
 * sa commune a fusionné. Une division ou une réunion, elle, relie des terrains
 * DIFFÉRENTS. Les confondre reviendrait à dire qu'une parcelle « est devenue »
 * les six morceaux qu'on en a tirés, ce qui n'est pas la même affirmation.
 *
 * On remonte donc la chaîne dans les deux sens en ne suivant que les liens
 * constatés.
 */
const chaineIdentite = computed(() => {
  const d = data.value
  if (!d) return []
  const surs = d.liens.filter((l) => l.certain)
  if (!surs.length) return []

  const avant = new Map(surs.map((l) => [l.id_apres, l.id_avant]))
  const apres = new Map(surs.map((l) => [l.id_avant, l.id_apres]))

  const chaine: string[] = [d.parcelle.id_parcelle]
  // `vus` protège d'un cycle : rien dans le schéma ne l'interdit formellement,
  // et une boucle ici figerait la page.
  const vus = new Set(chaine)

  let curseur = avant.get(d.parcelle.id_parcelle)
  while (curseur && !vus.has(curseur)) {
    chaine.unshift(curseur)
    vus.add(curseur)
    curseur = avant.get(curseur)
  }
  curseur = apres.get(d.parcelle.id_parcelle)
  while (curseur && !vus.has(curseur)) {
    chaine.push(curseur)
    vus.add(curseur)
    curseur = apres.get(curseur)
  }

  return chaine.map((id) => {
    const n = d.noeuds.find((x) => x.id === id)
    const lien = surs.find((l) => l.id_apres === id)
    return {
      id,
      commune: n?.commune ?? id.slice(0, 5),
      prefixe: id.slice(5, 8),
      section: n?.section ?? '',
      numero: n?.numero ?? '',
      vu_premier: n?.vu_premier ?? null,
      vu_dernier: n?.vu_dernier ?? null,
      presente: n?.presente ?? false,
      depuis: lien?.millesime ?? null,
      courant: id === d.parcelle.id_parcelle,
    }
  })
})

/**
 * Bilan de surface d'une division ou d'une réunion.
 *
 * Un découpage conserve le terrain : la somme des morceaux doit retrouver le
 * tout. L'écart mesure donc ce que la reconstitution laisse échapper — un
 * successeur non détecté, ou un recouvrement sous le seuil de 5%.
 */
/**
 * Montants à l'échelle qui se lit d'un coup d'œil.
 *
 * `maximumFractionDigits` sans `minimum` laisse tomber les décimales nulles :
 * 2 000 000 donne « 2 M€ » et non « 2,00 M€ ». Une colonne de montants où la
 * moitié des lignes traînent des zéros se lit deux fois moins vite.
 */
const euros = (v: number | null) => {
  if (v == null) return '—'
  const fr = (x: number, d: number) => x.toLocaleString('fr-FR', { maximumFractionDigits: d })
  if (Math.abs(v) >= 1_000_000) return `${fr(v / 1_000_000, 2)} M€`
  if (Math.abs(v) >= 1_000) return `${fr(v / 1_000, 1)} k€`
  return `${fr(v, 0)} €`
}

/**
 * Le prix au mètre carré reste en euros pleins.
 *
 * Il vit dans les centaines à quelques milliers : « 1,2 k€ » s'y lit moins bien
 * que « 1 200 € », alors que l'inverse est vrai pour le prix d'un bien. L'échelle
 * suit la grandeur, elle ne s'applique pas uniformément.
 */
const euroM2 = (v: number | null) =>
  v == null ? '—' : `${Math.round(v).toLocaleString('fr-FR')} €`

const mediane = (xs: number[]) => {
  if (!xs.length) return null
  const t = [...xs].sort((a, b) => a - b)
  const m = Math.floor(t.length / 2)
  return t.length % 2 ? t[m]! : (t[m - 1]! + t[m]!) / 2
}

/**
 * Les ventes regroupées par ce sur quoi elles portent.
 *
 * Une parcelle de copropriété porte jusqu'à 194 ventes dans le département :
 * les lister à plat ne raconte rien. Regroupées par nature de bien, elles
 * deviennent lisibles — et surtout comparables entre elles, ce qui est le seul
 * moyen de voir une évolution.
 *
 * Le regroupement se fait sur la composition du bien (« Appartement »,
 * « Appartement + Dépendance », « Terrain seul »), pas sur la nature juridique
 * de l'acte : c'est ce qui se vend qui détermine le prix, pas la forme du
 * contrat.
 */
/**
 * Ce sur quoi porte la vente, nommé honnêtement.
 *
 * DVF ne renseigne `type_local` que pour un local qui EXISTE. Une vente en
 * l'état futur d'achèvement porte donc des lots sans aucun type — et l'appeler
 * « terrain seul » serait faux : c'est un logement vendu sur plan, pas un
 * terrain. La présence de lots tranche.
 */
const libelleBien = (types: string[], avecLots: boolean) =>
  types.length
    ? [...types].sort().join(' + ')
    : avecLots
      ? 'Lot vendu sans local décrit'
      : 'Terrain seul'

const ventesParType = computed(() => {
  const v = data.value?.ventes ?? []
  // En dessous d'une poignée de ventes, la liste brute se lit mieux qu'un
  // regroupement qui ferait des groupes d'un élément.
  if (v.length < 5) return []

  const paquets = new Map<string, typeof v>()
  for (const x of v) {
    const cle = libelleBien(x.types, x.avec_lots)
    const p = paquets.get(cle)
    if (p) p.push(x)
    else paquets.set(cle, [x])
  }

  return [...paquets.entries()]
    .map(([libelle, ventes]) => {
      const prix = ventes.map((x) => x.valeur).filter((x): x is number => x != null)

      // Prix au mètre carré : seulement quand la surface bâtie est connue et non
      // nulle. Sur un lot de copropriété, la valeur foncière porte sur la MUTATION
      // entière — un appartement vendu avec sa cave et son garage compte une seule
      // fois. C'est donc bien le prix du bien, pas celui du seul appartement.
      const auM2 = ventes
        .filter((x) => x.valeur != null && x.surface_bati && x.surface_bati > 0)
        .map((x) => x.valeur! / x.surface_bati!)

      // Médiane annuelle : la moyenne serait emportée par une vente atypique, et
      // sur cinq ou dix ventes par an c'est vite arrivé.
      const parAnnee = new Map<number, number[]>()
      for (const x of ventes) {
        if (x.valeur == null) continue
        const a = Number(x.date_mutation.slice(0, 4))
        const l = parAnnee.get(a)
        if (l) l.push(x.valeur)
        else parAnnee.set(a, [x.valeur])
      }
      const serie = [...parAnnee.entries()]
        .map(([annee, xs]) => ({ annee, valeur: mediane(xs)!, n: xs.length }))
        .sort((a, b) => a.annee - b.annee)

      return {
        libelle,
        avecLots: ventes.some((x) => x.avec_lots),
        n: ventes.length,
        de: ventes[0]!.date_mutation,
        a: ventes[ventes.length - 1]!.date_mutation,
        medianePrix: mediane(prix),
        medianeM2: mediane(auM2),
        serie,
        courbe: courbeDe(serie.map((s) => s.valeur)),
      }
    })
    .sort((a, b) => b.n - a.n)
})

/**
 * Tracé d'une série, dans le même langage visuel que la frise communale.
 *
 * L'échelle verticale est bornée aux valeurs observées et NON à zéro : sur des
 * prix médians qui varient de quelques pour cent d'une année à l'autre, partir
 * de zéro donnerait une ligne rigoureusement plate. L'amplitude réelle est donc
 * montrée, et écrite en toutes lettres sous la courbe.
 */
function courbeDe(vals: number[]) {
  if (vals.length < 3) return null
  const min = Math.min(...vals)
  const max = Math.max(...vals)
  const etendue = max - min || 1
  const pts = vals.map((v, i) => ({
    x: (i / (vals.length - 1)) * 100,
    y: 100 - ((v - min) / etendue) * 92 - 4,
  }))
  const d = pts.map((p, i) => `${i ? 'L' : 'M'}${p.x.toFixed(2)},${p.y.toFixed(2)}`).join(' ')
  return { d, aire: `${d} L100,100 L0,100 Z`, min, max, pts }
}

/**
 * Ce qu'une vente dit — et surtout ce qu'elle ne dit pas.
 *
 * Une vente « avec lots » porte sur des lots de copropriété : la PARCELLE
 * appartient au syndicat et ne change pas de main. Croisé avec le fichier des
 * personnes morales sur sept ans, un changement de propriétaire accompagne 83 %
 * des ventes hors lots contre 18,6 % des ventes de lots. Afficher les deux de la
 * même façon laisserait croire à un changement de main quatre fois sur cinq à
 * tort.
 */
const portee = (v: { avec_lots: boolean }) =>
  v.avec_lots
    ? 'Vente de lots — la parcelle appartient à la copropriété et ne change pas de main'
    : 'Vente portant sur le terrain lui-même'

/**
 * Le retard de déclaration, en clair. Une vente met environ dix mois à
 * apparaître dans DVF (médiane mesurée), une sur dix plus de dix-huit. Ce n'est
 * pas un détail technique : c'est la borne de fraîcheur de tout ce que la fiche
 * affirme.
 */
const retard = (jours: number) => {
  const mois = Math.round(jours / 30.4)
  return mois < 1 ? 'déclarée le mois même' : `déclarée ${mois} mois plus tard`
}

const bilan = computed(() => {
  const d = data.value
  if (!d || !descendants.value.length) return null
  const avant = d.noeuds.find((n) => n.id === d.parcelle.id_parcelle)?.surface_m2 ?? null
  if (avant == null) return null
  const apres = descendants.value
    .reduce((somme, l) => {
      const n = d.noeuds.find((x) => x.id === l.id_apres)
      return somme + (n?.surface_m2 ?? 0)
    }, 0)
  if (!apres) return null
  return { avant, apres, ecart: (apres - avant) / avant }
})
</script>

<template>
  <UContainer class="py-8">
    <UAlert
      v-if="error"
      color="neutral"
      variant="subtle"
      icon="i-lucide-search-x"
      title="Parcelle inconnue"
      :description="
        error.statusCode === 404
          ? 'Cet identifiant ne correspond à aucune parcelle des relevés disponibles.'
          : 'La parcelle n’a pas pu être chargée.'
      "
    />

    <template v-else-if="data && p">
      <div class="mb-8">
        <NuxtLink :to="`/parcelles/${p.commune}`" class="text-sm text-muted hover:text-default">
          ← Parcellaire de {{ data.commune ?? p.commune }}
        </NuxtLink>

        <h1 class="mt-2 flex flex-wrap items-baseline gap-3 text-3xl font-semibold tracking-tight">
          <span>Parcelle {{ p.section }} {{ p.numero }}</span>
          <UBadge v-if="!p.presente" color="error" variant="subtle">disparue</UBadge>
        </h1>
        <p class="mt-1 font-mono text-sm text-dimmed">{{ p.id_parcelle }}</p>

        <!-- Le préfixe est une déduction, et la page doit le dire — c'est la même
             règle que sur les fiches communes. -->
        <UAlert
          v-if="data.absorbee"
          class="mt-4"
          color="neutral"
          variant="subtle"
          icon="i-lucide-git-merge"
        >
          <template #description>
            Le préfixe <code class="font-mono">{{ p.prefixe }}</code> de cette parcelle
            correspond au code INSEE
            <code class="font-mono">{{ data.absorbee.com }}</code>, celui de
            <LienCommune :code="data.absorbee.com" :nom="data.absorbee.libelle" />,
            commune qui a cessé d’exister
            <template v-if="data.absorbee.date_fin">en {{ data.absorbee.date_fin.slice(0, 4) }}</template>.
            Cette parcelle dépendait vraisemblablement de cette commune avant sa
            disparition — c’est une <strong class="font-medium">déduction</strong>,
            fondée sur la façon dont le cadastre numérote les terrains des communes
            absorbées.
          </template>
        </UAlert>
      </div>

      <!-- Identité -->
      <dl class="mb-10 grid grid-cols-2 gap-x-8 gap-y-4 sm:grid-cols-4">
        <div>
          <dt class="text-xs uppercase tracking-wide text-muted">Contenance</dt>
          <dd class="mt-1 font-mono text-lg tabular-nums">
            {{ surface(data.versions.at(-1)?.contenance) }}
          </dd>
          <dd class="text-xs text-dimmed">déclarée</dd>
        </div>
        <div>
          <dt class="text-xs uppercase tracking-wide text-muted">Surface</dt>
          <dd class="mt-1 font-mono text-lg tabular-nums">
            {{ surface(data.versions.at(-1)?.surface_m2) }}
          </dd>
          <dd class="text-xs text-dimmed">mesurée sur le tracé</dd>
        </div>
        <div>
          <dt class="text-xs uppercase tracking-wide text-muted">Créée</dt>
          <dd class="mt-1 font-mono text-lg tabular-nums">
            {{ p.cree_source ? p.cree_source.slice(0, 4) : '—' }}
          </dd>
          <dd class="text-xs text-dimmed">
            {{ p.anterieure_a_nos_releves ? 'avant nos relevés' : 'selon le cadastre' }}
          </dd>
        </div>
        <div>
          <dt class="text-xs uppercase tracking-wide text-muted">Observée</dt>
          <dd class="mt-1 font-mono text-lg tabular-nums">{{ p.n_versions }}</dd>
          <dd class="text-xs text-dimmed">
            état{{ p.n_versions > 1 ? 's' : '' }} distinct{{ p.n_versions > 1 ? 's' : '' }}
          </dd>
        </div>
      </dl>

      <!-- Filiation -->
      <section class="mb-10">
        <h2 class="mb-1 text-2xl font-semibold tracking-tight">D’où elle vient, ce qu’elle devient</h2>
        <p class="mb-4 text-sm text-muted">
          <template v-if="ascendants.length && descendants.length">
            {{ ascendants.length }} lien{{ ascendants.length > 1 ? 's' : '' }} vers l’amont,
            {{ descendants.length }} vers l’aval.
          </template>
          <template v-else-if="descendants.length">
            Ce terrain s’est réparti entre {{ descendants.length }} parcelle{{ descendants.length > 1 ? 's' : '' }}.
          </template>
          <template v-else-if="ascendants.length">
            Ce terrain provient de {{ ascendants.length }} parcelle{{ ascendants.length > 1 ? 's' : '' }} antérieure{{ ascendants.length > 1 ? 's' : '' }}.
          </template>
        </p>

        <UAlert
          v-if="changementsCommune.length"
          class="mb-4"
          color="warning"
          variant="subtle"
          icon="i-lucide-map-pin"
        >
          <template #description>
            Ce terrain a changé de commune.
            <template v-for="(l, i) in changementsCommune.slice(0, 3)" :key="i">
              En {{ l.millesime.slice(0, 4) }}, il passe de
              <LienCommune :code="l.id_avant.slice(0, 5)" :nom="nomCommune(l.id_avant.slice(0, 5))" />
              à
              <LienCommune :code="l.id_apres.slice(0, 5)" :nom="nomCommune(l.id_apres.slice(0, 5))" /><template
                v-if="l.id_apres.slice(5, 8) !== '000'"
              >, sous le préfixe <code class="font-mono">{{ l.id_apres.slice(5, 8) }}</code></template>.
            </template>
            <template v-if="changementsCommune.some((l) => l.certain)">
              Le tracé est rigoureusement identique de part et d’autre :
              <strong class="font-medium">le terrain n’a pas bougé, c’est la commune qui a changé autour de lui</strong>.
            </template>
          </template>
        </UAlert>

        <UAlert
          v-if="data.tronque"
          class="mb-4"
          color="neutral"
          variant="subtle"
          icon="i-lucide-scissors"
          title="Voisinage tronqué"
          :description="`Ce terrain est relié à ${data.atteints} parcelles, plus que ce graphe n’en peut montrer lisiblement. Seules les plus proches sont affichées — les autres se rejoignent en cliquant de proche en proche.`"
        />

        <GrapheFiliation
          :focus="p.id_parcelle"
          :noeuds="data.noeuds"
          :liens="data.liens"
          :communes="data.communes"
        />

        <!-- Le contrôle de conservation : un découpage ne crée ni ne détruit de
             terrain, l'écart mesure ce que la reconstitution laisse échapper. -->
        <div
          v-if="bilan"
          class="mt-4 flex flex-wrap items-baseline gap-x-6 gap-y-1 rounded-lg border border-default bg-elevated px-5 py-4 text-sm"
        >
          <span class="font-medium">Bilan de surface</span>
          <span class="font-mono tabular-nums">{{ surface(bilan.avant) }} avant</span>
          <span class="text-dimmed">→</span>
          <span class="font-mono tabular-nums">{{ surface(bilan.apres) }} répartis</span>
          <span
            class="font-mono tabular-nums"
            :class="Math.abs(bilan.ecart) < 0.02 ? 'text-muted' : 'text-ecart-600 dark:text-ecart-400'"
          >{{ bilan.ecart >= 0 ? '+' : '−' }}{{ Math.abs(bilan.ecart * 100).toFixed(1) }} %</span>
          <span class="text-xs text-dimmed">
            {{ Math.abs(bilan.ecart) < 0.02
              ? 'le terrain est intégralement retrouvé'
              : 'l’écart signale un successeur non rattaché' }}
          </span>
        </div>
      </section>

      <!-- Les codes successifs du même terrain -->
      <section v-if="chaineIdentite.length > 1" class="mb-10">
        <h2 class="mb-1 text-2xl font-semibold tracking-tight">Les codes qu’elle a portés</h2>
        <p class="mb-4 text-sm text-muted">
          {{ chaineIdentite.length }} identifiants pour un seul et même terrain. Le
          tracé est rigoureusement identique de l’un à l’autre : ce qui change, c’est
          la commune qui l’entoure, et donc son numéro au cadastre.
        </p>

        <ol class="overflow-hidden rounded-lg border border-default">
          <li
            v-for="(c, i) in chaineIdentite"
            :key="c.id"
            class="flex flex-wrap items-baseline gap-x-4 gap-y-1 border-default px-5 py-3"
            :class="[i > 0 && 'border-t', c.courant && 'bg-cadastre-50 dark:bg-cadastre-950']"
          >
            <NuxtLink
              :to="`/parcelle/${c.id}`"
              class="font-mono text-sm font-semibold"
              :class="c.courant ? 'text-cadastre-700 dark:text-cadastre-300' : 'hover:underline'"
            >{{ c.id }}</NuxtLink>

            <span class="text-sm text-muted">
              <LienCommune :code="c.commune" :nom="nomCommune(c.commune)" />
              <template v-if="c.prefixe !== '000'">
                · préfixe <code class="font-mono">{{ c.prefixe }}</code>
              </template>
            </span>

            <span class="ml-auto font-mono text-xs text-dimmed tabular-nums">
              <template v-if="c.depuis">à partir de {{ c.depuis }}</template>
              <template v-else-if="c.vu_premier">vu dès {{ c.vu_premier }}</template>
              <template v-if="!c.presente && c.vu_dernier"> · jusqu’au {{ c.vu_dernier }}</template>
            </span>

            <UBadge v-if="c.courant" size="sm" color="primary" variant="subtle">code actuel</UBadge>
          </li>
        </ol>
      </section>

      <!-- Mutations -->
      <section v-if="data.ventes.length || data.ventesHeritees.length" class="mb-10">
        <h2 class="mb-1 text-2xl font-semibold tracking-tight">Quand elle a changé de main</h2>
        <p class="mb-4 text-sm text-muted">
          Demandes de valeurs foncières, reconstituées depuis onze livraisons successives
          de la DGFiP. Une vente met environ dix mois à y apparaître, et l’année la plus
          récente n’est complète qu’aux trois quarts.
        </p>

        <!-- Vue regroupée : au-delà de quelques ventes, la liste à plat ne
             raconte rien. Une parcelle de copropriété en porte jusqu'à 194. -->
        <div v-if="ventesParType.length" class="mb-6 grid gap-4 sm:grid-cols-2">
          <div
            v-for="g in ventesParType"
            :key="g.libelle"
            class="rounded-lg border border-default px-5 py-4"
          >
            <div class="flex flex-wrap items-baseline gap-x-3">
              <h3 class="text-base font-semibold">{{ g.libelle }}</h3>
              <span class="font-mono text-xs text-dimmed tabular-nums">
                {{ g.n }} vente{{ g.n > 1 ? 's' : '' }}
              </span>
              <UBadge v-if="g.avecLots" size="sm" color="warning" variant="subtle">lots</UBadge>
            </div>

            <dl class="mt-3 grid grid-cols-2 gap-x-4 gap-y-1 text-sm">
              <div class="flex items-baseline justify-between gap-2">
                <dt class="text-muted">médiane</dt>
                <dd class="font-mono font-semibold tabular-nums">{{ euros(g.medianePrix) }}</dd>
              </div>
              <div v-if="g.medianeM2" class="flex items-baseline justify-between gap-2">
                <dt class="text-muted">au m²</dt>
                <dd class="font-mono font-semibold tabular-nums">{{ euroM2(g.medianeM2) }}</dd>
              </div>
            </dl>

            <div v-if="g.courbe" class="relative mt-3">
              <svg
                viewBox="0 0 100 100"
                preserveAspectRatio="none"
                class="h-12 w-full"
                role="img"
                :aria-label="`Prix médian par an, de ${euros(g.courbe.min)} à ${euros(g.courbe.max)}`"
              >
                <path :d="g.courbe.aire" fill="var(--color-cadastre-500)" opacity="0.12" />
                <path
                  :d="g.courbe.d"
                  fill="none"
                  stroke="var(--color-cadastre-500)"
                  stroke-width="1.5"
                  vector-effect="non-scaling-stroke"
                />
              </svg>
              <div class="mt-0.5 flex justify-between font-mono text-[0.65rem] text-dimmed">
                <span>{{ g.serie[0]?.annee }}</span>
                <span class="text-muted">
                  prix médian par an · {{ euros(g.courbe.min) }} → {{ euros(g.courbe.max) }}
                </span>
                <span>{{ g.serie[g.serie.length - 1]?.annee }}</span>
              </div>
            </div>

            <!-- Moins de trois années renseignées : il n'y a pas d'évolution à
                 tracer, et une courbe de deux points en suggérerait une. -->
            <p v-else class="mt-3 text-xs text-dimmed">
              {{ g.serie.length }} année{{ g.serie.length > 1 ? 's' : '' }} renseignée{{ g.serie.length > 1 ? 's' : '' }} —
              trop peu pour une évolution
            </p>
          </div>
        </div>

        <details v-if="ventesParType.length" class="rounded-lg border border-default">
          <summary class="cursor-pointer px-5 py-3 text-sm text-muted hover:text-default">
            Le détail des {{ data.ventes.length }} ventes
          </summary>
          <ul class="border-t border-default">
            <li
              v-for="(v, i) in data.ventes"
              :key="v.date_mutation + v.nature + i"
              class="flex flex-wrap items-baseline gap-x-4 gap-y-1 border-default px-5 py-2 text-sm"
              :class="i > 0 && 'border-t'"
            >
              <span class="font-mono text-xs tabular-nums text-dimmed">{{ v.date_mutation }}</span>
              <span>{{ libelleBien(v.types, v.avec_lots) }}</span>
              <span v-if="v.surface_bati" class="text-xs text-dimmed">{{ surface(v.surface_bati) }}</span>
              <span class="ml-auto font-mono font-semibold tabular-nums">{{ euros(v.valeur) }}</span>
            </li>
          </ul>
        </details>

        <ul v-else-if="data.ventes.length" class="rounded-lg border border-default">
          <li
            v-for="(v, i) in data.ventes"
            :key="v.date_mutation + v.nature"
            class="border-default px-5 py-4"
            :class="i > 0 && 'border-t'"
          >
            <div class="flex flex-wrap items-baseline gap-x-4 gap-y-1">
              <span class="font-mono text-sm tabular-nums">{{ dateLisible(v.date_mutation) }}</span>
              <span class="text-sm font-medium">{{ v.nature }}</span>
              <span class="ml-auto font-mono text-base font-semibold tabular-nums">
                {{ euros(v.valeur) }}
              </span>
            </div>

            <p class="mt-1 text-sm" :class="v.avec_lots ? 'text-warning' : 'text-muted'">
              {{ portee(v) }}
            </p>

            <p class="mt-1 text-xs text-dimmed">
              {{ libelleBien(v.types, v.avec_lots) }} ·
              <template v-if="v.surface_bati">{{ surface(v.surface_bati) }} bâtis · </template>
              <template v-if="v.surface_terrain">{{ surface(v.surface_terrain) }} de terrain · </template>
              {{ retard(v.retard_jours) }}
            </p>

            <!-- Deux actes du même jour sur la même parcelle, tous deux en
                 disposition 000001 : rien dans l'open data ne les sépare. On le
                 dit plutôt que d'afficher un prix qui n'est celui d'aucun des deux. -->
            <p v-if="v.n_prix > 1" class="mt-1 text-xs text-warning">
              {{ v.n_prix }} prix distincts sous la même référence — deux ventes du même
              jour sur cette parcelle, que la source ne permet pas de départager.
            </p>
          </li>
        </ul>

        <div v-else class="rounded-lg border border-default px-5 py-4">
          <p class="text-sm text-muted">
            Aucune vente à son nom. Son terrain, lui, a changé de main sous un autre
            numéro&nbsp;:
          </p>
          <ul class="mt-3 space-y-2">
            <li
              v-for="v in data.ventesHeritees"
              :key="v.herite_de + v.date_mutation"
              class="flex flex-wrap items-baseline gap-x-3 gap-y-1 text-sm"
            >
              <span class="font-mono text-xs tabular-nums text-dimmed">
                {{ dateLisible(v.date_mutation) }}
              </span>
              <NuxtLink :to="`/parcelle/${v.herite_de}`" class="font-mono text-xs hover:underline">
                {{ v.herite_de }}
              </NuxtLink>
              <span class="text-muted">{{ v.nature }}</span>
              <span class="font-mono tabular-nums">{{ euros(v.valeur) }}</span>
              <!-- La part héritée conditionne tout : un prix venu d'un prédécesseur
                   dont on ne tient que quelques pour cent ne dit rien de cette parcelle. -->
              <span v-if="v.part != null" class="text-xs text-dimmed">
                {{ v.filiation }} · {{ Math.round(v.part * 100) }} % de ce terrain vient de là
              </span>
            </li>
          </ul>
        </div>
      </section>

      <!-- Chronologie -->
      <section class="mb-10">
        <h2 class="mb-4 text-2xl font-semibold tracking-tight">Sa vie, relevé par relevé</h2>

        <ol class="space-y-0 border-l border-default pl-6">
          <li v-if="!p.apparition_observee" class="relative pb-6">
            <span class="absolute -left-[1.6rem] top-1.5 size-2.5 rounded-full bg-neutral-400" />
            <div class="font-medium">Déjà présente au premier relevé</div>
            <div class="text-sm text-muted">
              {{ dateLisible(p.vu_premier) }} — son existence est donc antérieure à ce
              que nous pouvons observer.
              <template v-if="p.cree_source">
                Le cadastre la déclare créée le
                <strong class="font-medium text-default">{{ dateLisible(p.cree_source) }}</strong><template
                  v-if="p.anterieure_a_nos_releves"
                >, soit {{ Math.round((new Date(p.vu_premier).getTime() - new Date(p.cree_source).getTime()) / 31557600000) }}
                  ans plus tôt</template>.
                Nous n’avons aucune image du terrain sur cette période : seule la date
                est connue.
              </template>
            </div>
          </li>

          <li v-for="(e, i) in chronologie" :key="i" class="relative pb-6">
            <span
              class="absolute -left-[1.6rem] top-1.5 size-2.5 rounded-full"
              :class="{
                'bg-cadastre-500': e.type === 'apparition',
                'bg-insee-400': e.type === 'modification',
                'bg-ecart-500': e.type === 'disparition',
                'bg-neutral-400': e.type === 'reapparition',
              }"
            />
            <div class="font-medium">{{ e.titre }}</div>
            <div class="text-sm text-muted">
              {{ dateLisible(e.millesime) }}
              <template v-if="e.detail?.length"> · {{ e.detail.join(', ') }}</template>
            </div>

            <p v-if="e.relations.length" class="mt-1 text-sm text-muted">
              <template v-if="e.type === 'disparition'">
                <template v-if="e.renumerotation">
                  Le tracé est rigoureusement identique de part et d’autre : le terrain
                  n’a pas bougé, seul son numéro change.
                </template>
                <template v-else>
                  Son terrain se retrouve dans
                  {{ e.relations.length }} parcelle{{ e.relations.length > 1 ? 's' : '' }}.
                </template>
              </template>
              <template v-else>
                Elle reprend du terrain de
                {{ e.relations.length }} parcelle{{ e.relations.length > 1 ? 's' : '' }}
                antérieure{{ e.relations.length > 1 ? 's' : '' }}.
              </template>
              <template v-if="e.horsCommune.length">
                <strong class="font-medium text-default">Le terrain change de commune</strong> à
                cette occasion.
              </template>
            </p>

            <ul v-if="e.relations.length" class="mt-2 flex flex-wrap gap-2">
              <li v-for="r in e.relations" :key="r.id">
                <NuxtLink
                  :to="`/parcelle/${r.id}`"
                  class="inline-flex items-baseline gap-2 rounded-md border border-default px-2.5 py-1 text-xs hover:bg-elevated"
                >
                  <span class="font-mono font-semibold">{{ r.libelle }}</span>
                  <span v-if="r.commune !== p.commune" class="text-ecart-600 dark:text-ecart-400">
                    {{ nomCommune(r.commune) }}
                  </span>
                  <span v-if="r.part != null" class="font-mono tabular-nums text-muted">
                    {{ Math.round(r.part * 100) }} %
                  </span>
                  <span class="font-mono tabular-nums text-dimmed">{{ surface(r.surface) }}</span>
                  <span
                    class="text-dimmed"
                    :title="r.certain ? 'Lien constaté : géométrie identique' : 'Lien déduit du recouvrement des surfaces'"
                  >{{ r.certain ? '· constaté' : '· déduit' }}</span>
                </NuxtLink>
              </li>
            </ul>
          </li>

          <li v-if="p.presente" class="relative">
            <span class="absolute -left-[1.6rem] top-1.5 size-2.5 rounded-full bg-cadastre-500" />
            <div class="font-medium">Toujours présente</div>
            <div class="text-sm text-muted">au dernier relevé, {{ dateLisible(p.vu_dernier) }}</div>
          </li>
        </ol>
      </section>

      <!-- États successifs : n'a d'intérêt que s'il y en a plusieurs. -->
      <section v-if="data.versions.length > 1">
        <h2 class="mb-4 text-2xl font-semibold tracking-tight">Ses états successifs</h2>
        <div class="overflow-x-auto rounded-lg border border-default">
          <table class="w-full text-sm">
            <thead class="bg-elevated text-left text-xs uppercase tracking-wide text-muted">
              <tr>
                <th class="px-4 py-2">État</th>
                <th class="px-4 py-2">Observé du</th>
                <th class="px-4 py-2">au</th>
                <th class="px-4 py-2 text-right">Contenance</th>
                <th class="px-4 py-2 text-right">Surface mesurée</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-default">
              <tr v-for="v in data.versions" :key="v.no_version">
                <td class="px-4 py-2 font-mono tabular-nums">{{ v.no_version }}</td>
                <td class="px-4 py-2 font-mono tabular-nums">{{ v.vu_debut }}</td>
                <td class="px-4 py-2 font-mono tabular-nums">{{ v.vu_fin ?? 'aujourd’hui' }}</td>
                <td class="px-4 py-2 text-right font-mono tabular-nums">{{ surface(v.contenance) }}</td>
                <td class="px-4 py-2 text-right font-mono tabular-nums">{{ surface(v.surface_m2) }}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </template>
  </UContainer>
</template>
