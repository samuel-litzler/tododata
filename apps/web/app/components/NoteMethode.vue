<script setup lang="ts">
/**
 * Note de méthode, affichée partout où le site présente une commune disparue.
 *
 * Le rattachement d'un territoire à une ancienne commune est une DÉDUCTION, pas
 * une donnée fournie telle quelle. Elle est solide, mais elle reste une
 * déduction : le site doit le dire au lieu de la présenter comme un fait brut.
 */
const props = withDefaults(defineProps<{ compact?: boolean }>(), { compact: false })
const ouverte = ref(!props.compact)
</script>

<template>
  <div
    class="rounded border text-sm"
    :style="{ borderColor: 'var(--ui-border)', background: 'var(--ui-bg-elevated)' }"
  >
    <button
      type="button"
      class="flex w-full items-center gap-2 px-3 py-2 text-left"
      :aria-expanded="ouverte"
      @click="ouverte = !ouverte"
    >
      <UIcon name="i-lucide-info" class="size-4 shrink-0" :style="{ color: 'var(--ui-text-dimmed)' }" />
      <span class="flex-1 font-medium">Comment ces communes sont retrouvées</span>
      <UIcon
        :name="ouverte ? 'i-lucide-chevron-up' : 'i-lucide-chevron-down'"
        class="size-4 shrink-0"
        :style="{ color: 'var(--ui-text-dimmed)' }"
      />
    </button>

    <div v-if="ouverte" class="space-y-2 px-3 pb-3" :style="{ color: 'var(--ui-text-muted)' }">
      <p>
        Quand une commune est absorbée, son territoire n'est pas redécoupé : le plan cadastral
        conserve ses parcelles regroupées à part, sous un numéro qui est celui de l'ancienne
        commune. C'est ce numéro qui permet de la retrouver et de la redessiner.
      </p>
      <p>
        <strong :style="{ color: 'var(--ui-text)' }">C'est une déduction, pas une donnée
        officielle.</strong>
        Le plan cadastral ne dit pas « ici se trouvait telle commune » : il conserve un
        découpage, et on le rapproche du registre historique des communes tenu par l'INSEE.
      </p>
      <p>
        Le rapprochement a été vérifié là où c'était possible. Le cadastre nomme lui-même
        l'ancienne commune dans
        <span class="font-mono">1 894</span> cas ; la déduction y donne le même résultat
        <span class="font-mono">1 894</span> fois sur <span class="font-mono">1 894</span>.
        Elle permet en plus d'identifier <span class="font-mono">772</span> territoires que le
        cadastre laisse anonymes.
      </p>
      <p v-if="!compact" class="text-xs">
        Restent des cas à ne pas confondre : quelques grandes villes découpent leur territoire
        en secteurs internes qui ne correspondent à aucune commune. Ils sont écartés lorsque le
        numéro ne correspond à aucune commune connue du registre.
      </p>
    </div>
  </div>
</template>
