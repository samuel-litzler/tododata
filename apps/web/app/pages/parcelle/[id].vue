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
