<script setup lang="ts">
const { data } = await useFetch('/api/departements')
useHead({ title: 'Départements' })

const tri = ref<'code' | 'absorbees'>('code')
const liste = computed(() => {
  const l = [...(data.value ?? [])]
  return tri.value === 'code'
    ? l.sort((a, b) => String(a.code).localeCompare(String(b.code)))
    : l.sort((a, b) => Number(b.nb_absorbees) - Number(a.nb_absorbees))
})
</script>

<template>
  <main class="mx-auto max-w-6xl px-5 py-10">
    <div class="eyebrow">Territoire</div>
    <h1 class="font-display mt-2 text-3xl sm:text-4xl">Les 101 départements</h1>
    <p class="mt-3 max-w-2xl" :style="{ color: 'var(--ui-text-muted)' }">
      Le nombre de communes absorbées mesure la mémoire cadastrale d'un département :
      combien de communes disparues son découpage en sections conserve encore.
    </p>

    <div class="mt-6 flex gap-2">
      <UButton
        :variant="tri === 'code' ? 'solid' : 'outline'"
        color="primary"
        size="sm"
        @click="tri = 'code'"
      >
        Par code
      </UButton>
      <UButton
        :variant="tri === 'absorbees' ? 'solid' : 'outline'"
        color="primary"
        size="sm"
        @click="tri = 'absorbees'"
      >
        Par absorptions
      </UButton>
    </div>

    <div class="mt-6 grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
      <NuxtLink
        v-for="d in liste"
        :key="d.code"
        :to="`/departements/${d.code}`"
        class="flex items-baseline gap-3 rounded border px-3 py-2.5 transition-colors hover:border-cadastre-500"
        :style="{ borderColor: 'var(--ui-border)' }"
      >
        <span class="w-8 shrink-0 font-mono text-sm text-cadastre-500 dark:text-cadastre-400">
          {{ d.code }}
        </span>
        <span class="min-w-0 flex-1">
          <span class="block text-sm">{{ d.nb_communes }} communes</span>
          <span class="block font-mono text-xs" :style="{ color: 'var(--ui-text-dimmed)' }">
            {{ d.km2 }} km²
          </span>
        </span>
        <span
          v-if="Number(d.nb_absorbees)"
          class="shrink-0 font-mono text-sm"
          :style="{ color: 'var(--color-ecart-500)' }"
        >
          +{{ d.nb_absorbees }}
        </span>
      </NuxtLink>
    </div>
  </main>
</template>
