<script setup lang="ts">
/**
 * Lien vers une commune, où qu'elle se trouve dans l'histoire.
 *
 * On pointe systématiquement vers /communes/<code> sans se demander si la
 * commune existe encore : cette page redirige d'elle-même vers /disparues/<code>
 * quand le code ne correspond plus à une commune vivante. Sans ça, chaque
 * endroit qui affiche un nom devrait d'abord savoir s'il est encore actif —
 * information que l'appelant n'a presque jamais.
 *
 * C'est ce qui rend le graphe entièrement parcourable : depuis n'importe quelle
 * commune on atteint ses absorbées, leurs sœurs, et l'absorbante de proche en
 * proche.
 */
const props = defineProps<{
  code: string | null | undefined
  nom?: string | null
  /** Affiche le code en petit à côté du nom. */
  avecCode?: boolean
}>()

const libelle = computed(() => props.nom ?? props.code ?? '—')
</script>

<template>
  <NuxtLink
    v-if="code"
    :to="`/communes/${code}`"
    class="underline decoration-cadastre-400 decoration-1 underline-offset-2 transition-colors hover:decoration-cadastre-600"
  >
    {{ libelle }}<span
      v-if="avecCode"
      class="ml-1 font-mono text-xs"
      :style="{ color: 'var(--ui-text-dimmed)' }"
    >{{ code }}</span>
  </NuxtLink>
  <span v-else>{{ libelle }}</span>
</template>
