<script setup lang="ts">
/**
 * Les deux horloges d'une commune sur un axe temporel unique : la bande des
 * millésimes où le cadastre l'a observée, et les jalons des mouvements INSEE.
 *
 * C'est la superposition qui porte l'information — un décalage de plusieurs
 * trimestres entre la date légale et l'observation est la règle, pas l'exception
 * (273 jours de retard médian mesurés sur les 514 disparitions).
 */
interface Presence {
  millesime: string
  present: boolean
  origine: string
}
interface Mouvement {
  mod: string
  date: string
  sens: string
}

const props = defineProps<{
  presence: Presence[]
  mouvements?: Mouvement[]
}>()

const W = 900
const yBande = 62
const hBande = 30

const ms = (d: string) => Date.parse(d + 'T00:00:00Z')

/** Jalons INSEE regroupés par date : un même événement produit plusieurs lignes. */
const jalons = computed(() => {
  const parDate = new Map<string, Mouvement[]>()
  for (const m of props.mouvements ?? []) {
    if (m.sens === 'interne') continue
    if (!parDate.has(m.date)) parDate.set(m.date, [])
    parDate.get(m.date)!.push(m)
  }
  return [...parDate.entries()].sort(([a], [b]) => a.localeCompare(b))
})

const bornes = computed(() => {
  const dates = [
    ...props.presence.map((p) => ms(p.millesime)),
    ...jalons.value.map(([d]) => ms(d)),
  ]
  const min = Math.min(...dates)
  const max = Math.max(...dates)
  const marge = (max - min) * 0.04 || 8.64e7
  return { min: min - marge, max: max + marge }
})

const X = (d: string) => {
  const { min, max } = bornes.value
  return 10 + ((ms(d) - min) / (max - min)) * (W - 20)
}

const hauteur = computed(() => (jalons.value.length ? 210 : 130))

/** Une cellule par millésime, large de l'intervalle réel jusqu'au suivant. */
const cellules = computed(() =>
  props.presence.map((p, i) => {
    const suivant = props.presence[i + 1]
    const x = X(p.millesime)
    const fin = suivant
      ? X(suivant.millesime)
      : x + (x - X(props.presence[i - 1]?.millesime ?? p.millesime))
    return {
      ...p,
      x,
      w: Math.max(3, fin - x - 1.2),
      couleur: !p.present
        ? 'var(--color-ardoise-300)'
        : p.origine === 'comblee'
          ? 'var(--color-ecart-300)'
          : 'var(--color-cadastre-500)',
      titre:
        p.millesime +
        (p.present
          ? p.origine === 'comblee'
            ? ' — comblé, absent de la source'
            : ' — observée'
          : ' — absente'),
    }
  }),
)

const annees = computed(() => {
  const a0 = new Date(bornes.value.min).getUTCFullYear()
  const a1 = new Date(bornes.value.max).getUTCFullYear()
  const pas = a1 - a0 > 14 ? 4 : a1 - a0 > 7 ? 2 : 1
  const out: number[] = []
  for (let a = Math.ceil(a0 / pas) * pas; a <= a1; a += pas) out.push(a)
  return out
})
</script>

<template>
  <div class="overflow-x-auto">
    <svg
      :viewBox="`0 0 ${W} ${hauteur}`"
      class="block h-auto w-full min-w-[640px]"
      role="img"
      :aria-label="`Présence cadastrale sur ${presence.length} millésimes et ${jalons.length} dates de mouvement INSEE`"
    >
      <!-- graduation annuelle -->
      <g>
        <template v-for="a in annees" :key="a">
          <line
            :x1="X(`${a}-01-01`)"
            :x2="X(`${a}-01-01`)"
            :y1="30"
            :y2="yBande + hBande + 8"
            stroke="var(--ui-border)"
            stroke-width="1"
          />
          <text
            :x="X(`${a}-01-01`)"
            :y="yBande + hBande + 24"
            text-anchor="middle"
            fill="var(--ui-text-dimmed)"
            font-family="var(--font-mono)"
            font-size="11"
          >
            {{ a }}
          </text>
        </template>
      </g>

      <!-- jalons INSEE, avec trait de rappel jusqu'à la bande -->
      <g v-if="jalons.length">
        <text
          x="10"
          y="16"
          fill="var(--color-insee-500)"
          font-family="var(--font-mono)"
          font-size="10.5"
          letter-spacing="0.1em"
        >
          REGISTRE INSEE
        </text>
        <template v-for="([date, evs], i) in jalons" :key="date">
          <line
            :x1="X(date)"
            :x2="X(date)"
            :y1="26"
            :y2="yBande + hBande"
            stroke="var(--color-insee-500)"
            stroke-width="1.2"
            stroke-dasharray="3 3"
            opacity="0.85"
          />
          <circle :cx="X(date)" :cy="26" r="4.5" fill="var(--color-insee-500)" />
          <text
            :x="X(date)"
            :y="140 + (i % 2) * 30"
            :text-anchor="X(date) > W * 0.75 ? 'end' : X(date) < W * 0.12 ? 'start' : 'middle'"
            fill="var(--ui-text)"
            font-family="var(--font-mono)"
            font-size="10.5"
          >
            {{ date }}
          </text>
          <text
            :x="X(date)"
            :y="153 + (i % 2) * 30"
            :text-anchor="X(date) > W * 0.75 ? 'end' : X(date) < W * 0.12 ? 'start' : 'middle'"
            fill="var(--ui-text-muted)"
            font-family="var(--font-mono)"
            font-size="10"
          >
            MOD {{ [...new Set(evs.map((e) => e.mod))].join(' · ') }} ({{ evs.length }})
          </text>
        </template>
      </g>

      <!-- la bande cadastrale -->
      <text
        x="10"
        :y="yBande - 10"
        fill="var(--color-cadastre-500)"
        font-family="var(--font-mono)"
        font-size="10.5"
        letter-spacing="0.1em"
      >
        CADASTRE — {{ presence.length }} MILLÉSIMES
      </text>
      <g>
        <rect
          v-for="c in cellules"
          :key="c.millesime"
          :x="c.x"
          :y="yBande"
          :width="c.w"
          :height="hBande"
          :fill="c.couleur"
          :opacity="c.present ? 1 : 0.55"
          rx="1.5"
        >
          <title>{{ c.titre }}</title>
        </rect>
      </g>
    </svg>
  </div>
</template>
