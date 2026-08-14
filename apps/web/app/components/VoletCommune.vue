<script setup lang="ts">
/**
 * Volet latéral : la vie d'une commune, ouvert au clic sur la carte.
 *
 * Il consomme /resume, qui ne transporte volontairement aucune géométrie — la
 * carte a déjà les contours, le volet doit s'ouvrir sans attendre.
 */
import type { ResumeCommune } from '~/types/commune'

const props = defineProps<{ code: string | null }>()
const emit = defineEmits<{ fermer: []; allerVers: [code: string] }>()

/**
 * Chargement piloté à la main plutôt que par useFetch.
 *
 * Le volet ne se remplit que sur interaction : il n'y a rien à rendre côté
 * serveur, et useFetch avec une URL conditionnelle expose un état `idle` avant
 * la première requête — état que la version précédente confondait avec « pas de
 * résultat », d'où le « Commune introuvable » affiché sur la carte de France
 * alors qu'aucune requête n'avait encore été lancée.
 */
const data = ref<ResumeCommune | null>(null)
const enCours = ref(false)
const erreur = ref<string | null>(null)

watch(
  () => props.code,
  async (code) => {
    erreur.value = null
    if (!code) {
      data.value = null
      return
    }
    enCours.value = true
    try {
      data.value = await $fetch<ResumeCommune>(`/api/communes/${code}/resume`)
    } catch (e) {
      const err = e as { statusMessage?: string; message?: string }
      erreur.value = err.statusMessage ?? err.message ?? 'erreur inconnue'
      data.value = null
    } finally {
      enCours.value = false
    }
  },
  { immediate: true },
)

const MODS: Record<string, string> = {
  '10': 'changement de nom',
  '21': 'rétablissement',
  '31': 'fusion simple',
  '32': 'commune nouvelle',
  '33': 'fusion association',
  '34': 'fusion association → simple',
  '35': 'suppression de commune déléguée',
  '41': 'changement de département',
  '50': 'transfert de chef-lieu',
  '70': 'associée → déléguée',
  '71': 'rétablissement de déléguée',
  '72': 'création de commune déléguée',
}

const absorbees = computed(() => data.value?.absorbees ?? [])
const presence = computed(() => data.value?.presence ?? [])

/** Les années couvertes par les relevés, pour parler en dates plutôt qu'en jargon. */
const periodeRelevee = computed(() => {
  const p = presence.value.filter((x) => x.present)
  if (!p.length) return null
  return { de: p[0]!.millesime.slice(0, 4), a: p.at(-1)!.millesime.slice(0, 4) }
})
const partout = computed(
  () => presence.value.length > 0 && presence.value.every((p) => p.present),
)

const anneeFusion = (a: { fusion_le: string | null; fin: string | null }) =>
  (a.fusion_le ?? a.fin ?? '').slice(0, 4) || null
</script>

<template>
  <aside
    class="flex h-full flex-col border-l"
    :style="{ borderColor: 'var(--ui-border)', background: 'var(--ui-bg-elevated)' }"
  >
    <div v-if="!code" class="flex h-full items-center justify-center p-8 text-center">
      <p class="max-w-xs text-sm" :style="{ color: 'var(--ui-text-dimmed)' }">
        Cliquez une commune sur la carte pour découvrir son histoire. Plus une commune
        est foncée, plus elle a absorbé de communes aujourd'hui disparues.
      </p>
    </div>

    <template v-else-if="data">
      <!-- en-tête -->
      <header class="border-b px-5 py-4" :style="{ borderColor: 'var(--ui-border)' }">
        <div class="flex items-start gap-3">
          <div class="min-w-0 flex-1">
            <div class="font-mono text-xs tracking-wide text-cadastre-500 dark:text-cadastre-400">
              {{ data.identite.code }} · dép. {{ data.identite.departement }}
            </div>
            <h2 class="font-display mt-0.5 truncate text-xl">{{ data.identite.nom }}</h2>
          </div>
          <UButton
            icon="i-lucide-x"
            color="neutral"
            variant="ghost"
            size="sm"
            aria-label="Fermer le volet"
            @click="emit('fermer')"
          />
        </div>

        <div class="mt-3 flex flex-wrap gap-1.5">
          <UBadge variant="subtle" color="neutral" size="sm">{{ data.identite.km2 }} km²</UBadge>
          <UBadge v-if="absorbees.length" variant="subtle" color="primary" size="sm">
            {{ absorbees.length }} commune{{ absorbees.length > 1 ? 's' : '' }} disparue{{
              absorbees.length > 1 ? 's' : ''
            }}
          </UBadge>
          <UBadge v-if="!partout && periodeRelevee" variant="subtle" color="neutral" size="sm">
            cartographiée depuis {{ periodeRelevee.de }}
          </UBadge>
        </div>
      </header>

      <div class="min-h-0 flex-1 overflow-y-auto px-5 py-4">
        <!-- identité officielle -->
        <section v-if="data.periodes.length">
          <div class="eyebrow">Dénominations officielles</div>
          <ul class="mt-2 space-y-1.5 text-sm">
            <li v-for="p in data.periodes" :key="p.debut" class="flex gap-2">
              <span class="shrink-0 font-mono text-xs" :style="{ color: 'var(--ui-text-dimmed)' }">
                {{ p.debut.slice(0, 4) }}–{{ p.fin ? p.fin.slice(0, 4) : '' }}
              </span>
              <span>{{ p.libelle }}</span>
            </li>
          </ul>
        </section>

        <!-- les communes avalées -->
        <section v-if="absorbees.length" class="mt-6">
          <div class="eyebrow">Communes disparues</div>
          <p class="mt-1.5 text-xs" :style="{ color: 'var(--ui-text-muted)' }">
            Elles ont fusionné dans {{ data.identite.nom }}. Leur territoire reste
            identifiable aujourd'hui.
          </p>
          <NoteMethode class="mt-2.5" compact />
          <ul class="mt-3 space-y-2">
            <NuxtLink
              v-for="a in absorbees"
              :key="a.code"
              :to="`/disparues/${a.code}`"
              class="block rounded border px-2.5 py-2 text-sm transition-colors hover:border-cadastre-500"
              :style="{ borderColor: 'var(--ui-border)' }"
            >
              <div class="flex items-baseline gap-2">
                <span class="font-mono text-xs text-cadastre-500 dark:text-cadastre-400">
                  {{ a.code }}
                </span>
                <span class="min-w-0 flex-1 truncate">{{ a.nom }}</span>
                <span class="shrink-0 font-mono text-xs" :style="{ color: 'var(--ui-text-dimmed)' }">
                  {{ a.km2 }} km²
                </span>
              </div>
              <div class="mt-0.5 font-mono text-xs" :style="{ color: 'var(--ui-text-dimmed)' }">
                <span v-if="anneeFusion(a)">rattachée en {{ anneeFusion(a) }}</span>
                <span v-else>rattachée de longue date</span>
              </div>
            </NuxtLink>
          </ul>
        </section>

        <!-- mouvements -->
        <section v-if="data.mouvements.length" class="mt-6">
          <div class="eyebrow">Étapes de son histoire</div>
          <ul class="mt-2 space-y-1.5 text-sm">
            <li v-for="(m, i) in data.mouvements" :key="i" class="flex gap-2">
              <span class="shrink-0 font-mono text-xs" :style="{ color: 'var(--ui-text-dimmed)' }">
                {{ m.date }}
              </span>
              <span
                class="shrink-0 font-mono text-xs"
                :class="m.sens === 'entrant' ? 'text-cadastre-600 dark:text-cadastre-400' : 'text-ecart-500 dark:text-ecart-300'"
              >
                {{ m.sens === 'entrant' ? '←' : '→' }}
              </span>
              <span class="min-w-0">
                <LienCommune
                  :code="m.sens === 'entrant' ? m.com_av : m.com_ap"
                  :nom="m.sens === 'entrant' ? m.libelle_av : m.libelle_ap"
                />
                <span :style="{ color: 'var(--ui-text-dimmed)' }">— {{ MODS[m.mod] ?? m.mod }}</span>
              </span>
            </li>
          </ul>
        </section>

        <!-- présence cadastrale -->
        <section v-if="data.presence?.length" class="mt-6">
          <div class="eyebrow">Sur les cartes, année par année</div>
          <div class="mt-2 flex gap-px">
            <span
              v-for="p in data.presence"
              :key="p.millesime"
              class="h-6 flex-1 rounded-sm"
              :title="`${p.millesime} — ${p.present ? 'cartographiée' : 'absente des cartes'}`"
              :style="{
                background: !p.present
                  ? 'var(--color-ardoise-300)'
                  : p.origine === 'comblee'
                    ? 'var(--color-ecart-300)'
                    : 'var(--color-cadastre-500)',
              }"
            />
          </div>
          <div class="mt-1 flex justify-between font-mono text-xs" :style="{ color: 'var(--ui-text-dimmed)' }">
            <span>{{ data.presence[0]?.millesime.slice(0, 4) }}</span>
            <span>{{ data.presence.at(-1)?.millesime.slice(0, 4) }}</span>
          </div>
        </section>
      </div>

      <footer class="border-t px-5 py-3" :style="{ borderColor: 'var(--ui-border)' }">
        <UButton
          :to="`/communes/${data.identite.code}`"
          color="primary"
          variant="soft"
          size="sm"
          trailing-icon="i-lucide-arrow-right"
          block
        >
          Voir la carte détaillée de son territoire
        </UButton>
      </footer>
    </template>

    <div
      v-else
      class="flex h-full items-center justify-center px-6 text-center text-sm"
      :style="{ color: 'var(--ui-text-dimmed)' }"
    >
      <span v-if="enCours">Chargement…</span>
      <span v-else-if="erreur">
        Impossible de charger cette commune.
        <span class="mt-1 block font-mono text-xs">{{ erreur }}</span>
      </span>
      <span v-else>Aucune donnée pour cette commune.</span>
    </div>
  </aside>
</template>
