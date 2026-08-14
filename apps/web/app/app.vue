<script setup lang="ts">
/**
 * Coquille de l'application. Le bandeau reste minimal : la recherche de commune
 * est l'action principale et doit être atteignable depuis n'importe quelle page.
 */
import type { ResultatRecherche } from '~/types/commune'

const recherche = ref('')
const router = useRouter()

const { data: suggestions } = await useFetch<ResultatRecherche[]>('/api/communes/search', {
  query: { q: recherche },
  default: () => [],
})

function ouvrir(code: string) {
  recherche.value = ''
  router.push(`/communes/${code}`)
}
</script>

<template>
  <div class="min-h-screen">
    <header
      class="sticky top-0 z-50 border-b"
      :style="{ borderColor: 'var(--ui-border)', background: 'var(--ui-bg)' }"
    >
      <div class="mx-auto flex max-w-6xl flex-wrap items-center gap-x-6 gap-y-3 px-5 py-4">
        <NuxtLink to="/" class="group">
          <div class="eyebrow">Nexus Analytics</div>
          <div class="font-display text-lg leading-tight group-hover:underline">
            Historique du cadastre
          </div>
        </NuxtLink>

        <nav class="flex gap-4 text-sm">
          <NuxtLink to="/" class="hover:underline" active-class="text-cadastre-600 dark:text-cadastre-400">Carte</NuxtLink>
          <NuxtLink to="/departements" class="hover:underline" active-class="text-cadastre-600 dark:text-cadastre-400">Départements</NuxtLink>
          <NuxtLink to="/codes" class="hover:underline" active-class="text-cadastre-600 dark:text-cadastre-400">Codes INSEE</NuxtLink>
          <NuxtLink to="/stats" class="hover:underline" active-class="text-cadastre-600 dark:text-cadastre-400">Contrôles</NuxtLink>
        </nav>

        <div class="relative ml-auto w-full max-w-sm">
          <UInput
            v-model="recherche"
            icon="i-lucide-search"
            placeholder="Code INSEE ou nom de commune…"
            class="w-full font-mono text-sm"
            :ui="{ base: 'font-mono' }"
          />
          <ul
            v-if="recherche.trim() && suggestions?.length"
            class="absolute z-[60] mt-1 max-h-80 w-full overflow-y-auto rounded border shadow-xl"
            :style="{ background: 'var(--ui-bg-elevated)', borderColor: 'var(--ui-border)' }"
          >
            <li v-for="s in suggestions.slice(0, 20)" :key="s.code">
              <button
                type="button"
                class="flex w-full items-baseline gap-2 px-3 py-1.5 text-left text-sm hover:bg-cadastre-50 dark:hover:bg-cadastre-950"
                @click="ouvrir(s.code)"
              >
                <span class="w-14 shrink-0 font-mono text-xs text-cadastre-500 dark:text-cadastre-400">
                  {{ s.code }}
                </span>
                <span class="truncate">{{ s.nom }}</span>
                <span
                  v-if="s.absorbees"
                  class="ml-auto shrink-0 font-mono text-xs text-ecart-500 dark:text-ecart-300"
                >
                  +{{ s.absorbees }}
                </span>
              </button>
            </li>
          </ul>
        </div>
      </div>
    </header>

    <NuxtPage />

    <footer
      v-if="$route.path !== '/'"
      class="mt-16 border-t py-8"
      :style="{ borderColor: 'var(--ui-border)' }"
    >
      <div class="mx-auto max-w-6xl px-5 text-sm" :style="{ color: 'var(--ui-text-dimmed)' }">
        <p>
          L'histoire des communes françaises, de leurs fusions et de leurs
          disparitions. Données publiques : cadastre (Etalab) et Code officiel
          géographique (INSEE).
        </p>
      </div>
    </footer>
  </div>
</template>
