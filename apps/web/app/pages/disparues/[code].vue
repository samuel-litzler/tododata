<script setup lang="ts">
/**
 * Ancienne adresse des communes disparues.
 *
 * Elle exposait dans l'URL une distinction qui n'a de sens que dans la base :
 * pour un visiteur, une commune reste une commune. Tout vit désormais sous
 * /communes/<code> ; on conserve cette route en redirection pour ne casser
 * aucun lien déjà partagé.
 */
const route = useRoute()
await navigateTo(`/communes/${String(route.params.code).toUpperCase()}`, { replace: true })
</script>

<template>
  <div />
</template>
