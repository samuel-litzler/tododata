<script setup lang="ts">
import type { Stats } from '~/types/commune'

const { data } = await useFetch<Stats>('/api/stats')
// `socle` vient d'un agrégat : la ligne existe toujours, mais le typage ne peut
// pas le savoir. On garde un garde-fou plutôt que des `!` dans le template.
const socle = computed(() => data.value?.socle)
useHead({ title: 'Tableau de bord' })

const nf = new Intl.NumberFormat('fr-FR')
</script>

<template>
  <main v-if="data && socle" class="mx-auto max-w-6xl px-5 py-10">
    <div class="max-w-2xl">
      <div class="eyebrow">État de la reconstruction</div>
      <h1 class="font-display mt-2 text-4xl leading-tight sm:text-5xl">
        Deux sources, deux horloges
      </h1>
      <p class="mt-4 text-lg" :style="{ color: 'var(--ui-text-muted)' }">
        Une commune fusionne à une date. Le cadastre le constate à une autre.
        {{ socle.millesimes }} relevés cartographiques confrontés au registre officiel,
        de {{ socle.du.slice(0, 4) }} à {{ socle.au.slice(0, 4) }}.
      </p>
    </div>

    <!-- chiffres de tête -->
    <dl class="mt-10 grid grid-cols-2 gap-x-6 gap-y-8 border-y py-7 sm:grid-cols-4"
        :style="{ borderColor: 'var(--ui-border)' }">
      <div>
        <dd class="font-mono text-3xl leading-none tabular">{{ nf.format(+socle.observations) }}</dd>
        <dt class="eyebrow mt-2">observations</dt>
      </div>
      <div>
        <dd class="font-mono text-3xl leading-none tabular">{{ nf.format(socle.codes) }}</dd>
        <dt class="eyebrow mt-2">communes rencontrées</dt>
      </div>
      <div>
        <dd class="font-mono text-3xl leading-none tabular text-ecart-500 dark:text-ecart-300">
          {{ data.retard?.median ?? '—' }} j
        </dd>
        <dt class="eyebrow mt-2">retard médian de la carte</dt>
      </div>
      <div>
        <dd class="font-mono text-3xl leading-none tabular">{{ socle.millesimes }}</dd>
        <dt class="eyebrow mt-2">relevés analysés</dt>
      </div>
    </dl>

    <!-- couverture comparée -->
    <section class="mt-12">
      <div class="eyebrow">Couverture</div>
      <h2 class="font-display mt-1 text-2xl">Le cadastre monte, l'INSEE descend</h2>
      <p class="mt-3 max-w-2xl text-sm" :style="{ color: 'var(--ui-text-muted)' }">
        L'INSEE enregistre des fusions : le nombre de communes décroît. Le cadastre, lui,
        finissait de cartographier la France, et chaque relevé ajoutait des communes jamais
        numérisées. Une règle du type « le nombre de communes doit décroître » aurait produit
        des milliers de fausses alertes.
      </p>
      <CourbeCouverture class="mt-6" :points="data.couverture" />
    </section>

    <!-- anomalies -->
    <section v-if="data.anomalies?.length" class="mt-12">
      <div class="eyebrow">Contrôles</div>
      <h2 class="font-display mt-1 text-2xl">Journal des anomalies</h2>
      <div class="mt-5 overflow-x-auto">
        <table class="w-full min-w-[420px] text-sm">
          <thead>
            <tr class="border-b" :style="{ borderColor: 'var(--ui-text)' }">
              <th class="eyebrow pb-2 pr-4 text-left">Règle</th>
              <th class="eyebrow pb-2 pr-4 text-left">Niveau</th>
              <th class="eyebrow pb-2 text-right">Cas</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="a in data.anomalies" :key="a.regle + a.niveau" class="border-b"
                :style="{ borderColor: 'var(--ui-border)' }">
              <td class="py-2 pr-4 font-mono">{{ a.regle }}</td>
              <td class="py-2 pr-4">
                <UBadge :color="a.niveau === 'anomalie' ? 'error' : 'neutral'" variant="subtle" size="sm">
                  {{ a.niveau }}
                </UBadge>
              </td>
              <td class="py-2 text-right font-mono tabular">{{ nf.format(a.n) }}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
  </main>
</template>
