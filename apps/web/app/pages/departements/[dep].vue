<script setup lang="ts">
const route = useRoute()
const dep = computed(() => String(route.params.dep).toUpperCase())

const { data, error } = await useFetch(() => `/api/departements/${dep.value}`)
useHead({ title: () => (data.value?.entete?.nom ? `${data.value.entete.nom} (${dep.value})` : `Département ${dep.value}`) })

const selection = ref<string | null>(null)
const carte = ref<{ cadrer: (b: [number, number, number, number]) => void } | null>(null)

// Une fois la carte prête, on cadre sur l'emprise du département plutôt que de
// laisser l'utilisateur chercher où il est.
const emprise = computed<[number, number, number, number] | null>(() => {
  const e = data.value?.entete
  if (!e) return null
  return [Number(e.xmin), Number(e.ymin), Number(e.xmax), Number(e.ymax)]
})

const avecAbsorptions = computed(
  () => data.value?.communes.filter((c) => Number(c.nb_absorbees) > 0) ?? [],
)
</script>

<template>
  <main class="mx-auto max-w-7xl px-5 py-8">
    <UAlert
      v-if="error"
      color="error"
      variant="subtle"
      :title="`Département ${dep} introuvable`"
      :description="error.statusMessage ?? ''"
    />

    <template v-else-if="data">
      <div class="border-b-2 pb-4" :style="{ borderColor: 'var(--ui-text)' }">
        <NuxtLink to="/departements" class="eyebrow hover:underline">← Tous les départements</NuxtLink>
        <h1 class="font-display mt-1.5 text-3xl sm:text-4xl">
          {{ data.entete.nom }}
          <span class="font-mono text-2xl font-normal" :style="{ color: 'var(--ui-text-dimmed)' }">
            ({{ data.entete.code }})
          </span>
        </h1>
        <div class="mt-2 text-sm" :style="{ color: 'var(--ui-text-muted)' }">
          <span v-if="data.entete.region">{{ data.entete.region }} · </span>
          <span class="font-mono">
            {{ data.entete.nb_communes }} communes · {{ data.entete.km2 }} km²
            <template v-if="Number(data.entete.nb_absorbees)">
              · {{ data.entete.nb_absorbees }} communes disparues absorbées
            </template>
          </span>
        </div>
      </div>

      <div class="mt-6 grid gap-6 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div class="h-[60vh] overflow-hidden rounded border" :style="{ borderColor: 'var(--ui-border)' }">
          <CarteFrance
            ref="carte"
            :selection="selection"
            :departement="dep"
            :emprise="emprise"
            @selectionner="selection = $event"
          />
        </div>
        <div class="h-[60vh] overflow-hidden rounded border" :style="{ borderColor: 'var(--ui-border)' }">
          <VoletCommune :code="selection" @fermer="selection = null" />
        </div>
      </div>

      <section v-if="avecAbsorptions.length" class="mt-10">
        <div class="eyebrow">Mémoire cadastrale</div>
        <h2 class="font-display mt-1 text-2xl">
          {{ avecAbsorptions.length }} communes conservent un territoire absorbé
        </h2>
        <div class="mt-5 grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
          <button
            v-for="c in avecAbsorptions"
            :key="c.code"
            type="button"
            class="flex items-baseline gap-2.5 rounded border px-3 py-2 text-left transition-colors hover:border-cadastre-500"
            :style="{ borderColor: selection === c.code ? 'var(--color-cadastre-500)' : 'var(--ui-border)' }"
            @click="selection = c.code ?? null"
          >
            <span class="shrink-0 font-mono text-xs text-cadastre-500 dark:text-cadastre-400">
              {{ c.code }}
            </span>
            <span class="min-w-0 flex-1 truncate text-sm">{{ c.nom }}</span>
            <span class="shrink-0 font-mono text-xs" :style="{ color: 'var(--color-ecart-500)' }">
              +{{ c.nb_absorbees }}
            </span>
          </button>
        </div>
      </section>

      <section class="mt-10">
        <div class="eyebrow">Toutes les communes</div>
        <div class="mt-4 grid gap-x-6 gap-y-1 sm:grid-cols-2 lg:grid-cols-3">
          <NuxtLink
            v-for="c in data.communes"
            :key="c.code"
            :to="`/communes/${c.code}`"
            class="flex items-baseline gap-2 py-0.5 text-sm hover:underline"
          >
            <span class="w-12 shrink-0 font-mono text-xs" :style="{ color: 'var(--ui-text-dimmed)' }">
              {{ c.code }}
            </span>
            <span class="truncate">{{ c.nom }}</span>
          </NuxtLink>
        </div>
      </section>
    </template>
  </main>
</template>
