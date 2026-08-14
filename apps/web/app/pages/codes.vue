<script setup lang="ts">
/**
 * Inventaire des codes INSEE. La page qui montre qu'un code n'est pas une
 * identité stable : il est attribué, puis un jour plus personne ne le porte.
 */
useHead({ title: 'Codes INSEE' })

const recherche = ref('')
const etat = ref<'tous' | 'actifs' | 'eteints'>('tous')

interface LigneCode {
  code: string
  nom: string
  departement: string
  actif: boolean
  fin: string | null
  repris_par: string | null
}

const { data } = await useFetch<{
  totaux: { actifs: number; eteints: number }
  lignes: LigneCode[]
  tronque: boolean
}>('/api/codes', { query: { q: recherche, etat } })

// `totaux` vient d'un agrégat : la ligne existe toujours, mais le typage ne peut
// pas le savoir.
const totaux = computed(() => data.value?.totaux)

const nf = new Intl.NumberFormat('fr-FR')
</script>

<template>
  <main class="mx-auto max-w-5xl px-5 py-10">
    <div class="eyebrow">Inventaire</div>
    <h1 class="font-display mt-2 text-3xl sm:text-4xl">Les codes INSEE</h1>
    <p class="mt-3 max-w-2xl" :style="{ color: 'var(--ui-text-muted)' }">
      Un code INSEE n'est pas une identité permanente. Certains désignent une commune
      aujourd'hui ; d'autres en ont désigné une, parfois pendant des siècles, et plus
      personne ne les porte. Les seconds gardent pourtant un territoire, toujours
      identifiable sur le terrain.
    </p>

    <dl
      v-if="totaux"
      class="mt-8 grid grid-cols-2 gap-6 border-y py-6 sm:grid-cols-3"
      :style="{ borderColor: 'var(--ui-border)' }"
    >
      <div>
        <dd class="font-mono text-3xl leading-none tabular">{{ nf.format(totaux.actifs) }}</dd>
        <dt class="eyebrow mt-2">codes en service</dt>
      </div>
      <div>
        <dd class="font-mono text-3xl leading-none tabular" :style="{ color: 'var(--color-ecart-500)' }">
          {{ nf.format(totaux.eteints) }}
        </dd>
        <dt class="eyebrow mt-2">codes éteints</dt>
      </div>
      <div>
        <dd class="font-mono text-3xl leading-none tabular">
          {{ nf.format(totaux.actifs + totaux.eteints) }}
        </dd>
        <dt class="eyebrow mt-2">codes connus depuis 1943</dt>
      </div>
    </dl>

    <div class="mt-6 flex flex-wrap items-center gap-3">
      <UInput
        v-model="recherche"
        icon="i-lucide-search"
        placeholder="Code ou nom…"
        class="w-full max-w-xs font-mono text-sm"
      />
      <div class="flex gap-2">
        <UButton
          v-for="o in [
            { v: 'tous', l: 'Tous' },
            { v: 'actifs', l: 'En service' },
            { v: 'eteints', l: 'Éteints' },
          ]"
          :key="o.v"
          size="sm"
          :variant="etat === o.v ? 'solid' : 'outline'"
          color="primary"
          @click="etat = o.v as typeof etat"
        >
          {{ o.l }}
        </UButton>
      </div>
    </div>

    <p v-if="data?.tronque" class="mt-3 text-xs" :style="{ color: 'var(--ui-text-dimmed)' }">
      400 premiers codes affichés — affinez la recherche pour cibler.
    </p>

    <div v-if="data" class="mt-5 overflow-x-auto">
      <table class="w-full min-w-[560px] text-sm">
        <thead>
          <tr class="border-b" :style="{ borderColor: 'var(--ui-text)' }">
            <th class="eyebrow pb-2 pr-4 text-left">Code</th>
            <th class="eyebrow pb-2 pr-4 text-left">Nom</th>
            <th class="eyebrow pb-2 pr-4 text-left">Dép.</th>
            <th class="eyebrow pb-2 pr-4 text-left">État</th>
            <th class="eyebrow pb-2 text-left">Devenu</th>
          </tr>
        </thead>
        <tbody>
          <tr
            v-for="l in data.lignes"
            :key="l.code"
            class="border-b"
            :style="{ borderColor: 'var(--ui-border)' }"
          >
            <td class="py-2 pr-4 font-mono">
              <NuxtLink
                :to="`/communes/${l.code}`"
                class="underline decoration-cadastre-400 underline-offset-2"
              >{{ l.code }}</NuxtLink>
            </td>
            <td class="py-2 pr-4">
              <LienCommune :code="l.code" :nom="l.nom" />
            </td>
            <td class="py-2 pr-4 font-mono" :style="{ color: 'var(--ui-text-dimmed)' }">
              {{ l.departement }}
            </td>
            <td class="py-2 pr-4">
              <UBadge :color="l.actif ? 'success' : 'neutral'" variant="subtle" size="sm">
                {{ l.actif ? 'en service' : `éteint ${l.fin ? l.fin.slice(0, 4) : ''}` }}
              </UBadge>
            </td>
            <td class="py-2">
              <LienCommune v-if="l.repris_par" :code="l.repris_par" :nom="l.repris_par" />
              <span v-else :style="{ color: 'var(--ui-text-dimmed)' }">—</span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </main>
</template>
