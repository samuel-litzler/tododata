<script setup lang="ts">
/** Les deux comptes de communes dans le temps. Le croisement est le seul point annoté. */
const props = defineProps<{ points: { millesime: string; cadastre: number; insee: number }[] }>()

const W = 900
const H = 320
const L = 62
const R = 16
const T = 18
const B = 40

const ms = (d: string) => Date.parse(d + 'T00:00:00Z')

const echelle = computed(() => {
  const xs = props.points.map((p) => ms(p.millesime))
  const vals = props.points.flatMap((p) => [p.cadastre, p.insee])
  const lo = Math.floor((Math.min(...vals) - 200) / 500) * 500
  const hi = Math.ceil((Math.max(...vals) + 200) / 500) * 500
  const x0 = Math.min(...xs)
  const x1 = Math.max(...xs)
  return {
    lo,
    hi,
    X: (d: string) => L + ((ms(d) - x0) / (x1 - x0)) * (W - L - R),
    Y: (v: number) => T + ((hi - v) / (hi - lo)) * (H - T - B),
  }
})

const graduations = computed(() => {
  const { lo, hi } = echelle.value
  const out: number[] = []
  for (let v = lo; v <= hi; v += 500) out.push(v)
  return out
})

const annees = computed(() => [
  ...new Set(props.points.map((p) => p.millesime.slice(0, 4))),
].filter((_, i) => i % 2 === 0))

const chemin = (cle: 'cadastre' | 'insee') => {
  const { X, Y } = echelle.value
  return props.points
    .map((p, i) => (i ? 'L' : 'M') + X(p.millesime).toFixed(1) + ' ' + Y(p[cle]).toFixed(1))
    .join(' ')
}

/** Premier millésime où le cadastre dépasse l'INSEE. */
const croisement = computed(() => props.points.find((p) => p.cadastre > p.insee) ?? null)
const dernier = computed(() => props.points.at(-1)!)
</script>

<template>
  <div>
    <div class="mb-3 flex flex-wrap gap-x-6 gap-y-1 font-mono text-xs" :style="{ color: 'var(--ui-text-muted)' }">
      <span class="inline-flex items-center gap-2">
        <i class="inline-block h-[3px] w-4 rounded" style="background: var(--color-insee-500)" />
        INSEE — communes de plein exercice
      </span>
      <span class="inline-flex items-center gap-2">
        <i class="inline-block h-[3px] w-4 rounded" style="background: var(--color-cadastre-500)" />
        Cadastre — communes observées
      </span>
    </div>

    <div class="overflow-x-auto">
      <svg :viewBox="`0 0 ${W} ${H}`" class="block h-auto w-full min-w-[560px]" role="img"
           aria-label="Deux courbes : le compte INSEE décroît tandis que le compte cadastral croît, les deux se croisant en cours de période.">
        <template v-for="v in graduations" :key="v">
          <line :x1="L" :x2="W - R" :y1="echelle.Y(v)" :y2="echelle.Y(v)"
                stroke="var(--ui-border)" stroke-width="1" />
          <text :x="L - 10" :y="echelle.Y(v) + 4" text-anchor="end" fill="var(--ui-text-dimmed)"
                font-family="var(--font-mono)" font-size="11">{{ v.toLocaleString('fr-FR') }}</text>
        </template>

        <text v-for="a in annees" :key="a" :x="echelle.X(`${a}-01-01`)" :y="H - 14"
              text-anchor="middle" fill="var(--ui-text-dimmed)"
              font-family="var(--font-mono)" font-size="11">{{ a }}</text>

        <path :d="chemin('insee')" fill="none" stroke="var(--color-insee-500)" stroke-width="2.4"
              stroke-dasharray="5 4" stroke-linejoin="round" stroke-linecap="round" />
        <path :d="chemin('cadastre')" fill="none" stroke="var(--color-cadastre-500)" stroke-width="2.4"
              stroke-linejoin="round" stroke-linecap="round" />

        <circle :cx="echelle.X(dernier.millesime)" :cy="echelle.Y(dernier.insee)" r="4"
                fill="var(--color-insee-500)" />
        <circle :cx="echelle.X(dernier.millesime)" :cy="echelle.Y(dernier.cadastre)" r="4"
                fill="var(--color-cadastre-500)" />

        <template v-if="croisement">
          <line :x1="echelle.X(croisement.millesime)" :x2="echelle.X(croisement.millesime)"
                :y1="T" :y2="H - B" stroke="var(--color-ecart-500)" stroke-width="1"
                stroke-dasharray="2 3" opacity="0.8" />
          <text :x="echelle.X(croisement.millesime) - 8" :y="T + 26" text-anchor="end"
                fill="var(--color-ecart-500)" font-family="var(--font-mono)" font-size="11.5">
            croisement
          </text>
        </template>
      </svg>
    </div>
  </div>
</template>
