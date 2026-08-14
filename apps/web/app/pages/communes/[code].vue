<script setup lang="ts">
import type { FicheCommune, DisparueResume } from '~/types/commune'

definePageMeta({ key: (route) => route.fullPath })

const route = useRoute()
const code = computed(() => String(route.params.code).toUpperCase())

// Type explicite : l'URL dynamique empêche Nuxt de choisir parmi les routes
// qui matchent /api/communes/*, il en inférerait l'union.
/**
 * URL unique pour toute commune, vivante ou disparue.
 *
 * Séparer /communes et /disparues faisait fuiter dans l'URL une distinction qui
 * n'a de sens que dans la base : pour un visiteur, une commune reste une
 * commune, qu'elle existe encore ou non. La page interroge donc les deux
 * sources et affiche la variante qui correspond.
 */
const { data, error } = await useFetch<FicheCommune>(() => `/api/communes/${code.value}`)

// Awaité dans le setup, et non dans un watchEffect : un effet asynchrone n'est
// pas attendu par le rendu serveur, la fiche historique n'apparaissait donc pas
// dans le HTML initial.
const disparue =
  error.value?.statusCode === 404
    ? await $fetch<DisparueResume>(`/api/disparues/${code.value}`).catch(() => null)
    : null

const nom = computed(
  () => data.value?.identite?.nom_cog ?? data.value?.identite?.nom_cadastre ?? code.value,
)
useHead({ title: () => `${nom.value} (${code.value})` })

const absorbees = computed(
  () => data.value?.territoires?.filter((t) => t.nature === 'absorbee') ?? [],
)
// Les secteurs internes des grandes villes ne racontent aucune fusion : on les
// laisse fondus dans le territoire d'origine plutôt que d'exposer une catégorie
// qui n'apprend rien au visiteur.
const territoiresAffiches = computed(
  () => data.value?.territoires?.filter((t) => t.nature !== 'quartier') ?? [],
)
const entrants = computed(() => data.value?.mouvements?.filter((m) => m.sens === 'entrant') ?? [])
const sortants = computed(() => data.value?.mouvements?.filter((m) => m.sens === 'sortant') ?? [])

const vus = computed(() => data.value?.presence?.filter((p) => p.present).length ?? 0)
const combles = computed(
  () => data.value?.presence?.filter((p) => p.origine === 'comblee').length ?? 0,
)

const MODS: Record<string, string> = {
  '10': 'Changement de nom',
  '20': 'Création',
  '21': 'Rétablissement',
  '30': 'Suppression',
  '31': 'Fusion simple',
  '32': 'Création de commune nouvelle',
  '33': 'Fusion association',
  '34': 'Transformation de fusion association en fusion simple',
  '35': 'Suppression de commune déléguée',
  '41': 'Changement de code dû à un changement de département',
  '50': 'Changement de code dû à un transfert de chef-lieu',
  '70': 'Transformation de commune associée en commune déléguée',
  '71': 'Rétablissement de commune déléguée',
  '72': 'Création de commune déléguée',
}
</script>

<template>
  <main class="mx-auto max-w-6xl px-5 py-10">
    <FicheDisparue v-if="disparue" :fiche="disparue" />

    <UAlert
      v-else-if="error"
      color="error"
      variant="subtle"
      :title="`Commune ${code} introuvable`"
      :description="error.statusMessage ?? 'Ce code ne figure dans aucun registre.'"
    />

    <template v-else-if="data">
      <div class="border-b-2 pb-4" :style="{ borderColor: 'var(--ui-text)' }">
        <div class="font-mono text-sm tracking-wide text-cadastre-500 dark:text-cadastre-400">
          {{ code }}
          <span v-if="data.identite.departement" :style="{ color: 'var(--ui-text-dimmed)' }">
            · dép. {{ data.identite.departement }}
          </span>
        </div>
        <h1 class="font-display mt-1 text-3xl sm:text-4xl">{{ nom }}</h1>
        <div
          v-if="data.identite.nom_cadastre && data.identite.nom_cadastre !== data.identite.nom_cog"
          class="mt-2 font-mono text-sm"
          :style="{ color: 'var(--ui-text-dimmed)' }"
        >
          au cadastre : {{ data.identite.nom_cadastre }}
        </div>

        <div class="mt-4 flex flex-wrap gap-2">
          <UBadge variant="subtle" :color="vus === data.presence.length ? 'success' : 'neutral'">
            {{ vus }}/{{ data.presence.length }} millésimes
          </UBadge>
          <UBadge v-if="combles" variant="subtle" color="error">
            {{ combles }} millésime{{ combles > 1 ? 's' : '' }} comblé{{ combles > 1 ? 's' : '' }}
          </UBadge>
          <UBadge v-if="absorbees.length" variant="subtle" color="primary">
            {{ absorbees.length }} commune{{ absorbees.length > 1 ? 's' : '' }} absorbée{{ absorbees.length > 1 ? 's' : '' }}
          </UBadge>
          <UBadge v-if="data.identite.arm_parent" variant="subtle" color="warning">
            arrondissement de {{ data.identite.arm_parent }}
          </UBadge>
        </div>
      </div>

      <!-- les deux horloges -->
      <section class="mt-10">
        <div class="eyebrow">Les deux horloges</div>
        <h2 class="font-display mt-1 text-2xl">Observation cadastrale et mouvements administratifs</h2>
        <div class="mt-4 flex flex-wrap gap-x-5 gap-y-1 font-mono text-xs" :style="{ color: 'var(--ui-text-muted)' }">
          <span class="inline-flex items-center gap-1.5">
            <i class="inline-block size-3 rounded-sm" style="background: var(--color-cadastre-500)" />observée
          </span>
          <span class="inline-flex items-center gap-1.5">
            <i class="inline-block size-3 rounded-sm" style="background: var(--color-ecart-300)" />comblée
          </span>
          <span class="inline-flex items-center gap-1.5">
            <i class="inline-block size-3 rounded-sm" style="background: var(--color-ardoise-300)" />absente
          </span>
          <span class="inline-flex items-center gap-1.5">
            <i class="inline-block size-3 rounded-full" style="background: var(--color-insee-500)" />mouvement INSEE
          </span>
        </div>
        <FriseMillesimes class="mt-4" :presence="data.presence" :mouvements="data.mouvements" />
      </section>

      <!-- carte -->
      <section v-if="data.territoires.length" class="mt-12">
        <div class="eyebrow">Découpage cadastral actuel</div>
        <h2 class="font-display mt-1 text-2xl">
          {{ absorbees.length ? 'Ce que la commune a avalé' : 'Territoire' }}
        </h2>
        <p v-if="absorbees.length" class="mt-2 max-w-2xl text-sm" :style="{ color: 'var(--ui-text-muted)' }">
          Quand une commune est absorbée, le cadastre ne fusionne pas ses sections : il conserve
          son découpage et lui affecte un préfixe égal à son ancien numéro de commune. On lit donc
          ici des communes disparues, parfois bien avant toute donnée numérique.
        </p>
        <CarteTerritoires class="mt-4" :territoires="data.territoires" :nom="nom" />
        <NoteMethode v-if="absorbees.length" class="mt-4" compact />
      </section>

      <!-- identité officielle -->
      <section v-if="data.periodes.length" class="mt-12">
        <div class="eyebrow">Registre INSEE</div>
        <h2 class="font-display mt-1 text-2xl">Identité officielle depuis 1943</h2>
        <div class="mt-4 overflow-x-auto">
          <table class="w-full min-w-[420px] text-sm">
            <thead>
              <tr class="border-b" :style="{ borderColor: 'var(--ui-text)' }">
                <th class="eyebrow pb-2 pr-4 text-left">Dénomination</th>
                <th class="eyebrow pb-2 pr-4 text-left">Début</th>
                <th class="eyebrow pb-2 text-left">Fin</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="p in data.periodes" :key="p.debut + p.libelle" class="border-b"
                  :style="{ borderColor: 'var(--ui-border)' }">
                <td class="py-2 pr-4">{{ p.libelle }}</td>
                <td class="py-2 pr-4 font-mono">{{ p.debut }}</td>
                <td class="py-2 font-mono">
                  <span v-if="p.fin">{{ p.fin }}</span>
                  <span v-else class="text-cadastre-500 dark:text-cadastre-400">en cours</span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <!-- filiation -->
      <section v-if="entrants.length || sortants.length" class="mt-12">
        <div class="eyebrow">Filiation</div>
        <h2 class="font-display mt-1 text-2xl">Mouvements de territoire</h2>
        <div class="mt-4 overflow-x-auto">
          <table class="w-full min-w-[600px] text-sm">
            <thead>
              <tr class="border-b" :style="{ borderColor: 'var(--ui-text)' }">
                <th class="eyebrow pb-2 pr-4 text-left">Sens</th>
                <th class="eyebrow pb-2 pr-4 text-left">Date d'effet</th>
                <th class="eyebrow pb-2 pr-4 text-left">Code</th>
                <th class="eyebrow pb-2 pr-4 text-left">Commune</th>
                <th class="eyebrow pb-2 text-left">Mouvement</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="(m, i) in [...entrants, ...sortants]" :key="i" class="border-b"
                  :style="{ borderColor: 'var(--ui-border)' }">
                <td class="py-2 pr-4" :class="m.sens === 'entrant'
                    ? 'text-cadastre-600 dark:text-cadastre-400'
                    : 'text-ecart-500 dark:text-ecart-300'">
                  {{ m.sens === 'entrant' ? 'absorbe' : 'versée à' }}
                </td>
                <td class="py-2 pr-4 font-mono">{{ m.date }}</td>
                <td class="py-2 pr-4 font-mono">{{ m.sens === 'entrant' ? m.com_av : m.com_ap }}</td>
                <td class="py-2 pr-4">
                  <LienCommune
                    :code="m.sens === 'entrant' ? m.com_av : m.com_ap"
                    :nom="m.sens === 'entrant' ? m.libelle_av : m.libelle_ap"
                  />
                  <span v-if="m.sens === 'entrant' && m.typecom_av !== 'COM'"
                        class="ml-1 font-mono text-xs" :style="{ color: 'var(--ui-text-dimmed)' }">
                    {{ m.typecom_av }}
                  </span>
                </td>
                <td class="py-2">
                  <span class="rounded px-1.5 py-0.5 font-mono text-xs"
                        style="background: var(--color-insee-50); color: var(--color-insee-600)">
                    {{ m.mod }}
                  </span>
                  <span class="ml-1.5">{{ MODS[m.mod] }}</span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <!-- détail des territoires -->
      <section v-if="data.territoires.length" class="mt-12">
        <div class="eyebrow">Détail</div>
        <h2 class="font-display mt-1 text-2xl">Territoires et identités</h2>
        <div class="mt-4 overflow-x-auto">
          <table class="w-full min-w-[560px] text-sm">
            <thead>
              <tr class="border-b" :style="{ borderColor: 'var(--ui-text)' }">
                <th class="eyebrow pb-2 pr-4 text-left">Préfixe</th>
                <th class="eyebrow pb-2 pr-4 text-left">Code reconstitué</th>
                <th class="eyebrow pb-2 pr-4 text-left">Dénomination</th>
                <th class="eyebrow pb-2 pr-4 text-left">Fusion</th>
                <th class="eyebrow pb-2 text-right">km²</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="t in territoiresAffiches" :key="t.prefixe" class="border-b"
                  :style="{ borderColor: 'var(--ui-border)' }">
                <td class="py-2 pr-4 font-mono">{{ t.prefixe }}</td>
                <td class="py-2 pr-4 font-mono">
                  <NuxtLink
                    v-if="t.code"
                    :to="`/disparues/${t.code}`"
                    class="underline decoration-cadastre-400 underline-offset-2"
                  >{{ t.code }}</NuxtLink>
                  <span v-else :style="{ color: 'var(--ui-text-dimmed)' }">—</span>
                </td>
                <td class="py-2 pr-4">
                  <template v-if="t.nom_insee ?? t.nom_cadastre">
                    <LienCommune v-if="t.code" :code="t.code" :nom="t.nom_insee ?? t.nom_cadastre" />
                    <template v-else>{{ t.nom_insee ?? t.nom_cadastre }}</template>
                  </template>
                  <span v-else :style="{ color: 'var(--ui-text-dimmed)' }">
                    territoire d'origine de {{ nom }}
                  </span>
                </td>
                <td class="py-2 pr-4 font-mono">
                  <span v-if="t.fusion_le">{{ t.fusion_le }}</span>
                  <span v-else-if="t.nature === 'absorbee'" :style="{ color: 'var(--ui-text-dimmed)' }">
                    fusion ancienne
                  </span>
                  <span v-else :style="{ color: 'var(--ui-text-dimmed)' }">—</span>
                </td>
                <td class="py-2 text-right font-mono tabular">{{ t.km2 }}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <!-- anomalies -->
      <section v-if="data.anomalies.length" class="mt-10 space-y-3">
        <UAlert
          v-for="(a, i) in data.anomalies"
          :key="i"
          :color="a.regle === 'R-SRC-001' ? 'error' : 'primary'"
          variant="subtle"
          :title="a.regle === 'R-SRC-001' ? 'Trou de millésime comblé' : 'Absence authentique'"
          :description="
            a.regle === 'R-SRC-001'
              ? `Ce code est absent de ${a.detail?.millesimes_manquants} millésime(s) intermédiaire(s) puis revient, sans mouvement INSEE correspondant. Traité comme un défaut de publication amont : la présence est réputée continue, et l'écart reste tracé sous la règle ${a.regle}.`
              : `L'interruption correspond à un rétablissement de commune acté par l'INSEE. Elle n'est délibérément pas comblée — règle ${a.regle}.`
          "
        />
      </section>
    </template>
  </main>
</template>
