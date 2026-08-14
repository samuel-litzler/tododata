<script setup lang="ts">
/**
 * La carte est la page d'accueil : on entre par le territoire, pas par des
 * chiffres. Le volet de droite s'ouvre au clic et raconte la commune.
 */
const selection = ref<string | null>(null)
const carte = ref<{ cadrer: (b: [number, number, number, number]) => void } | null>(null)

useHead({ title: 'Carte des communes' })

// Le code sélectionné vit dans l'URL : un lien vers une commune précise reste
// partageable, et le retour navigateur se comporte comme attendu.
const route = useRoute()
const router = useRouter()
onMounted(() => {
  if (typeof route.query.c === 'string') selection.value = route.query.c
})
watch(selection, (c) => {
  router.replace({ query: c ? { c } : {} })
})
</script>

<template>
  <main class="flex h-[calc(100vh-73px)] flex-col lg:flex-row">
    <div class="relative min-h-[52vh] flex-1 lg:min-h-0">
      <CarteFrance
        ref="carte"
        :selection="selection"
        @selectionner="selection = $event"
      />
    </div>

    <div class="w-full shrink-0 lg:w-[380px]">
      <VoletCommune :code="selection" @fermer="selection = null" />
    </div>
  </main>
</template>
