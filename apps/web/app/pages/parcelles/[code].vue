<script setup lang="ts">
/**
 * Évolution du parcellaire d'une commune, relevé par relevé.
 *
 * Page distincte de la fiche commune, et non un onglet de plus : le parcellaire
 * pèse plusieurs milliers de géométries qu'il serait absurde de charger à chaque
 * consultation d'une fiche. On y vient quand on veut le voir.
 */
import type { FeatureCollection } from 'geojson'

definePageMeta({ key: (route) => route.fullPath })

const route = useRoute()
const code = computed(() => String(route.params.code).toUpperCase())

interface Reponse {
  code: string
  millesimes: string[]
  parcelles: FeatureCollection
}

// Type explicite : l'URL dynamique empêche Nuxt de choisir parmi les routes qui
// matchent /api/communes/*, il en inférerait l'union.
const { data, error, status } = await useFetch<Reponse>(
  () => `/api/communes/${code.value}/parcelles`,
  {
    // Rendu côté client seulement : la charge utile se compte en méga-octets, la
    // faire transiter deux fois (payload SSR + hydratation) doublerait le poids
    // de la page pour un contenu qui n'a de sens qu'une fois la carte montée.
    server: false,
    lazy: true,
  },
)

const fiche = await $fetch<{ identite?: { nom_cog?: string; nom_cadastre?: string } }>(
  `/api/communes/${code.value}`,
).catch(() => null)

const nom = computed(
  () => fiche?.identite?.nom_cog ?? fiche?.identite?.nom_cadastre ?? code.value,
)
useHead({ title: () => `Parcelles de ${nom.value}` })

// Le nombre de PARCELLES, pas de versions : une parcelle redessinée en compte
// plusieurs, et afficher ce total gonflé donnerait une idée fausse du territoire.
const nParcelles = computed(() => {
  const vues = new Set<string>()
  for (const f of data.value?.parcelles.features ?? []) {
    if (f.properties?.id) vues.add(String(f.properties.id))
  }
  return vues.size
})
</script>

<template>
  <UContainer class="py-8">
    <div class="mb-6">
      <NuxtLink
        :to="`/communes/${code}`"
        class="text-sm text-muted hover:text-default"
      >← Retour à {{ nom }}</NuxtLink>

      <h1 class="mt-2 text-3xl font-semibold tracking-tight">
        Évolution du parcellaire
      </h1>
      <p class="mt-1 text-muted">
        {{ nom }}
        <span class="font-mono text-sm text-dimmed">({{ code }})</span>
        <template v-if="nParcelles">
          · <span class="font-mono tabular-nums">{{ nParcelles.toLocaleString('fr-FR') }}</span>
          parcelles suivies
        </template>
      </p>
    </div>

    <!-- `idle` autant que `pending` : avec server:false, useFetch n'a encore rien
         demandé au moment du rendu serveur et expose `idle`. Le traiter comme un
         résultat vide ferait afficher « aucune parcelle » à chaque premier rendu,
         avant même que la requête ne parte. -->
    <div
      v-if="status === 'pending' || status === 'idle'"
      class="flex h-96 items-center justify-center"
    >
      <div class="text-center">
        <UIcon name="i-lucide-loader-circle" class="size-6 animate-spin text-muted" />
        <p class="mt-3 text-sm text-muted">Chargement de l’historique parcellaire…</p>
      </div>
    </div>

    <UAlert
      v-else-if="error"
      color="neutral"
      variant="subtle"
      icon="i-lucide-map-off"
      title="Parcellaire indisponible"
      :description="
        error.statusCode === 404
          ? 'Le parcellaire de ce département n’a pas encore été relevé. Seule la Moselle (57) l’est pour l’instant.'
          : 'Le parcellaire n’a pas pu être chargé.'
      "
    />

    <template v-else-if="data && data.parcelles.features.length">
      <FriseParcelles
        :key="code"
        :code="code"
        :millesimes="data.millesimes"
        :parcelles="data.parcelles"
      />

      <div class="mt-6 rounded-lg border border-default bg-elevated p-5 text-sm leading-relaxed">
        <h2 class="mb-2 font-semibold">Comment lire cette carte</h2>
        <p class="text-muted">
          Chaque relevé du cadastre est un instantané. En déplaçant le curseur, on
          passe de l’un à l’autre et l’on voit le découpage se transformer : une
          parcelle <span class="text-cadastre-600 dark:text-cadastre-400">apparaît</span>
          quand elle entre pour la première fois au cadastre,
          <span class="text-insee-600 dark:text-insee-400">se redessine</span> quand son
          tracé change, et <span class="text-ecart-600 dark:text-ecart-400">disparaît</span>
          quand elle cesse d’exister — le plus souvent absorbée par un nouveau
          découpage voisin.
        </p>
        <p class="mt-3 text-muted">
          Le premier relevé ne signale aucune apparition : à cette date, tout le
          parcellaire est nouveau <em>pour nous</em>, pas pour le cadastre. La
          plupart de ces terrains existaient déjà bien avant.
        </p>
        <p class="mt-3 text-dimmed">
          Un contour n’est considéré comme modifié que s’il s’est déplacé de plus de
          25 cm. En deçà, il s’agit du bruit de recalcul de la source, qui republie
          ses coordonnées avec de très légères variations à chaque édition.
        </p>
      </div>
    </template>

    <UAlert
      v-else
      color="neutral"
      variant="subtle"
      icon="i-lucide-map-off"
      title="Aucune parcelle"
      description="Cette commune n’a aucune parcelle dans les relevés disponibles."
    />
  </UContainer>
</template>
