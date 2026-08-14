<script setup lang="ts">
/**
 * Fiche d'une commune qui n'existe plus, rendue à l'intérieur de /communes/<code>.
 *
 * Son territoire reste dessinable : quand une commune est absorbée, le découpage
 * cadastral de celle qui l'accueille conserve ses limites. C'est la seule source
 * qui permette de la représenter aujourd'hui.
 */
import type { DisparueResume } from '~/types/commune'

const props = defineProps<{ fiche: DisparueResume }>()
const fiche = computed(() => props.fiche)

const anneeFin = computed(() => fiche.value.periodes.at(-1)?.fin?.slice(0, 4) ?? null)
const absorption = computed(() => fiche.value.mouvements.find((m) => m.sens === 'sortant') ?? null)

const MODS: Record<string, string> = {
  '31': 'fusion simple',
  '32': 'cr\u00e9ation d\u2019une commune nouvelle',
  '33': 'fusion association',
  '34': 'transformation en fusion simple',
  '35': 'suppression de commune d\u00e9l\u00e9gu\u00e9e',
  '41': 'changement de d\u00e9partement',
  '50': 'transfert de chef-lieu',
}

/* ---- vignette de situation ---- */
const W = 760
const aplatir = (g: DisparueResume['contexte_geometrie']): number[][][] => {
  if (!g) return []
  const polys =
    g.type === 'MultiPolygon' ? (g.coordinates as number[][][][]) : [g.coordinates as number[][][]]
  return polys.flat()
}

const vue = computed(() => {
  const t = fiche.value.territoire
  if (!t) return null
  // On cadre sur la commune d'accueil : voir le territoire disparu DANS son
  // ensemble est tout l'int\u00e9r\u00eat de la vignette.
  const anneaux = [...aplatir(fiche.value.contexte_geometrie), ...aplatir(t.geometrie)]
  if (!anneaux.length) return null
  const bb = [Infinity, Infinity, -Infinity, -Infinity]
  for (const r of anneaux)
    for (const [x, y] of r) {
      bb[0] = Math.min(bb[0]!, x!)
      bb[1] = Math.min(bb[1]!, y!)
      bb[2] = Math.max(bb[2]!, x!)
      bb[3] = Math.max(bb[3]!, y!)
    }
  const [x0, y0, x1, y1] = bb as [number, number, number, number]
  const PAD = 12
  const kx = Math.cos((((y0 + y1) / 2) * Math.PI) / 180)
  const dx = (x1 - x0) * kx || 1e-6
  const dy = y1 - y0 || 1e-6
  const H = Math.max(220, Math.min(460, Math.round((W - 2 * PAD) * (dy / dx)) + 2 * PAD))
  const s = Math.min((W - 2 * PAD) / dx, (H - 2 * PAD) / dy)
  const ox = (W - dx * s) / 2
  const oy = (H - dy * s) / 2
  const X = (lon: number) => ox + (lon - x0) * kx * s
  const Y = (lat: number) => H - oy - (lat - y0) * s
  const chemin = (rings: number[][][]) =>
    rings
      .map(
        (r) =>
          r.map(([x, y], i) => (i ? 'L' : 'M') + X(x!).toFixed(1) + ' ' + Y(y!).toFixed(1)).join('') +
          'Z',
      )
      .join(' ')
  return {
    H,
    contexte: chemin(aplatir(fiche.value.contexte_geometrie)),
    territoire: chemin(aplatir(t.geometrie)),
  }
})
</script>

<template>

      <div class="border-b-2 pb-4" :style="{ borderColor: 'var(--ui-text)' }">
        <div class="font-mono text-sm tracking-wide" :style="{ color: 'var(--ui-text-dimmed)' }">
          {{ fiche.code }}
          <span v-if="fiche.territoire"> · dép. {{ fiche.territoire.departement }}</span>
        </div>
        <h1 class="font-display mt-1 text-3xl sm:text-4xl">{{ fiche.nom }}</h1>
        <p class="mt-3 text-lg" :style="{ color: 'var(--ui-text-muted)' }">
          <template v-if="anneeFin && fiche.territoire">
            Commune jusqu'en {{ anneeFin }}. Son territoire fait aujourd'hui partie de
            <NuxtLink
              :to="`/communes/${fiche.territoire.absorbante_code}`"
              class="underline decoration-cadastre-400 underline-offset-4"
            >{{ fiche.territoire.absorbante_nom }}</NuxtLink>.
          </template>
          <template v-else-if="anneeFin">Commune jusqu'en {{ anneeFin }}.</template>
          <template v-else>Cette commune existe toujours.</template>
        </p>

        <div class="mt-4 flex flex-wrap gap-2">
          <UBadge v-if="fiche.territoire" variant="subtle" color="neutral">
            {{ fiche.territoire.km2 }} km²
          </UBadge>
          <UBadge v-if="absorption" variant="subtle" color="primary">
            {{ MODS[absorption.mod] ?? 'mouvement ' + absorption.mod }}
          </UBadge>
          <UBadge v-if="fiche.soeurs.length" variant="subtle" color="neutral">
            {{ fiche.soeurs.length }} autre{{ fiche.soeurs.length > 1 ? 's' : '' }} commune{{
              fiche.soeurs.length > 1 ? 's' : ''
            }}
            dans la même fusion
          </UBadge>
        </div>
      </div>

      <!-- situation -->
      <section v-if="vue" class="mt-9">
        <div class="eyebrow">Son territoire aujourd'hui</div>
        <h2 class="font-display mt-1 text-xl">
          Dans {{ fiche.territoire!.absorbante_nom }}
        </h2>
        <p class="mt-2 max-w-2xl text-sm" :style="{ color: 'var(--ui-text-muted)' }">
          Les limites de {{ fiche.nom }} n'ont pas disparu avec la commune : le découpage
          cadastral de {{ fiche.territoire!.absorbante_nom }} les a conservées.
        </p>
        <NoteMethode class="mt-4" />
        <div
          class="mt-4 overflow-hidden rounded border"
          :style="{ background: 'var(--plan)', borderColor: 'var(--ui-border)' }"
        >
          <svg
            :viewBox="`0 0 ${W} ${vue.H}`"
            class="block h-auto w-full"
            role="img"
            :aria-label="`${fiche.nom} situé dans ${fiche.territoire!.absorbante_nom}`"
          >
            <path
              v-if="vue.contexte"
              :d="vue.contexte"
              fill="var(--color-ardoise-200)"
              stroke="var(--color-ardoise-400)"
              stroke-width="1"
              fill-rule="evenodd"
            />
            <path
              :d="vue.territoire"
              fill="var(--color-cadastre-500)"
              fill-opacity="0.85"
              stroke="var(--color-cadastre-700)"
              stroke-width="1.2"
              fill-rule="evenodd"
            />
          </svg>
        </div>
      </section>

      <!-- identité -->
      <section class="mt-9">
        <div class="eyebrow">Dénominations</div>
        <div class="mt-3 overflow-x-auto">
          <table class="w-full min-w-[380px] text-sm">
            <thead>
              <tr class="border-b" :style="{ borderColor: 'var(--ui-text)' }">
                <th class="eyebrow pb-2 pr-4 text-left">Nom</th>
                <th class="eyebrow pb-2 pr-4 text-left">De</th>
                <th class="eyebrow pb-2 text-left">À</th>
              </tr>
            </thead>
            <tbody>
              <tr
                v-for="p in fiche.periodes"
                :key="p.debut"
                class="border-b"
                :style="{ borderColor: 'var(--ui-border)' }"
              >
                <td class="py-2 pr-4">{{ p.libelle }}</td>
                <td class="py-2 pr-4 font-mono">{{ p.debut }}</td>
                <td class="py-2 font-mono">{{ p.fin ?? '—' }}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <!-- les autres communes de la même fusion -->
      <section v-if="fiche.soeurs.length" class="mt-9">
        <div class="eyebrow">La même fusion</div>
        <h2 class="font-display mt-1 text-xl">
          {{ fiche.nom }} n'était pas seule
        </h2>
        <div class="mt-3 grid gap-2 sm:grid-cols-2">
          <NuxtLink
            v-for="s in fiche.soeurs"
            :key="s.code"
            :to="`/communes/${s.code}`"
            class="flex items-baseline gap-2.5 rounded border px-3 py-2 text-sm transition-colors hover:border-cadastre-500"
            :style="{ borderColor: 'var(--ui-border)' }"
          >
            <span class="shrink-0 font-mono text-xs" :style="{ color: 'var(--ui-text-dimmed)' }">
              {{ s.code }}
            </span>
            <span class="min-w-0 flex-1 truncate">{{ s.nom }}</span>
            <span v-if="s.fin" class="shrink-0 font-mono text-xs" :style="{ color: 'var(--ui-text-dimmed)' }">
              {{ s.fin.slice(0, 4) }}
            </span>
          </NuxtLink>
        </div>
      </section>

      <div v-if="fiche.territoire" class="mt-10">
        <UButton
          :to="`/communes/${fiche.territoire.absorbante_code}`"
          color="primary"
          variant="soft"
          trailing-icon="i-lucide-arrow-right"
        >
          Voir {{ fiche.territoire.absorbante_nom }} aujourd'hui
        </UButton>
      </div>
</template>
