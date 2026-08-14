<script setup lang="ts">
/**
 * Le territoire d'une commune, découpé en groupes de sections cadastrales.
 *
 * Ce découpage n'est pas décoratif : quand une commune est absorbée, le cadastre
 * ne fusionne pas ses sections avec celles de l'absorbante — il conserve son
 * découpage et lui affecte un préfixe égal à son ancien numéro de commune. La
 * carte montre donc littéralement les communes disparues, y compris celles
 * effacées bien avant toute donnée numérique.
 *
 * Pas de fond de carte : les géométries cadastrales suivent le tracé parcellaire,
 * elles sont plus fines que n'importe quelle tuile, et une dépendance externe
 * n'apporterait rien ici.
 */
import type { Territoire } from '~/types/commune'

const props = defineProps<{ territoires: Territoire[]; nom: string }>()

const survole = ref<number | null>(null)
const W = 900

// Une poignée de grandes villes découpent leur territoire en secteurs internes
// qui ne correspondent à aucune commune disparue. Ils font partie du territoire
// d'origine : on les peint comme lui et on ne les nomme pas — les distinguer
// n'apprendrait rien sur l'histoire de la commune.
const estOrigine = (t: Territoire) => t.nature === 'noyau' || t.nature === 'quartier'
const libelle = (t: Territoire) =>
  t.nom_insee ?? t.nom_cadastre ?? 'territoire d\'origine'

/** Anneaux aplatis, tous polygones confondus, + emprise commune. */
const prepare = computed(() => {
  const anneaux: { i: number; pts: number[][] }[] = []
  const bb = [Infinity, Infinity, -Infinity, -Infinity]

  props.territoires.forEach((t, i) => {
    if (!t.geometrie) return
    const polys =
      t.geometrie.type === 'MultiPolygon'
        ? (t.geometrie.coordinates as number[][][][])
        : [t.geometrie.coordinates as number[][][]]
    for (const poly of polys) {
      for (const ring of poly) {
        if (ring.length < 4) continue
        for (const [x, y] of ring) {
          bb[0] = Math.min(bb[0]!, x!)
          bb[1] = Math.min(bb[1]!, y!)
          bb[2] = Math.max(bb[2]!, x!)
          bb[3] = Math.max(bb[3]!, y!)
        }
        anneaux.push({ i, pts: ring })
      }
    }
  })
  return { anneaux, bb }
})

const geo = computed(() => {
  const [x0, y0, x1, y1] = prepare.value.bb as [number, number, number, number]
  if (!Number.isFinite(x0)) return null
  const PAD = 14
  // À cette latitude un degré de longitude est plus court qu'un degré de latitude.
  const kx = Math.cos((((y0 + y1) / 2) * Math.PI) / 180)
  const dx = (x1 - x0) * kx
  const dy = y1 - y0
  const H = Math.max(320, Math.min(620, Math.round((W - 2 * PAD) * (dy / dx)) + 2 * PAD))
  const s = Math.min((W - 2 * PAD) / dx, (H - 2 * PAD) / dy)
  const ox = (W - dx * s) / 2
  const oy = (H - dy * s) / 2
  return {
    H,
    X: (lon: number) => ox + (lon - x0) * kx * s,
    // latitude vers le haut : l'axe Y du SVG est inversé
    Y: (lat: number) => H - oy - (lat - y0) * s,
  }
})

/** Un seul path par territoire, tous ses anneaux concaténés (règle evenodd pour les trous). */
const chemins = computed(() => {
  const g = geo.value
  if (!g) return []
  const parTerritoire = new Map<number, string>()
  for (const { i, pts } of prepare.value.anneaux) {
    let d = parTerritoire.get(i) ?? ''
    pts.forEach(([x, y], k) => {
      d += (k ? 'L' : 'M') + g.X(x!).toFixed(1) + ' ' + g.Y(y!).toFixed(1)
    })
    d += 'Z'
    parTerritoire.set(i, d)
  }
  return [...parTerritoire.entries()].map(([i, d]) => ({ i, d, t: props.territoires[i]! }))
})

/**
 * La couleur encode le TEMPS, pas une catégorie arbitraire : plus l'absorption
 * est récente, plus la teinte est saturée. Les territoires dont la disparition
 * précède le registre INSEE restent au ton le plus pâle.
 */
const RAMPE = ['#e4eaea', '#cfe0e0', '#a3c6c7', '#71a9ab', '#428a8d', '#1d6b6f']
function teinte(t: Territoire): string {
  if (estOrigine(t)) return 'var(--color-ardoise-600)'
  const a = Number((t.fusion_le ?? t.fin_insee ?? '').slice(0, 4))
  if (!a) return RAMPE[0]!
  if (a < 1950) return RAMPE[1]!
  if (a < 1980) return RAMPE[2]!
  if (a < 2010) return RAMPE[3]!
  if (a < 2019) return RAMPE[4]!
  return RAMPE[5]!
}

const surfaceTotale = computed(() =>
  props.territoires.reduce((s, t) => s + Number(t.km2 ?? 0), 0),
)

/** Étiquette au centroïde du plus grand anneau, si le territoire est assez large. */
const etiquettes = computed(() => {
  const g = geo.value
  if (!g) return []
  return props.territoires
    .map((t, i) => {
      const part = Number(t.km2 ?? 0) / (surfaceTotale.value || 1)
      if (part < 0.045) return null
      const anneaux = prepare.value.anneaux.filter((a) => a.i === i)
      if (!anneaux.length) return null
      const plusGrand = anneaux.reduce((a, b) => (b.pts.length > a.pts.length ? b : a))
      const sx = plusGrand.pts.reduce((s, p) => s + p[0]!, 0) / plusGrand.pts.length
      const sy = plusGrand.pts.reduce((s, p) => s + p[1]!, 0) / plusGrand.pts.length
      const texte = estOrigine(t) ? '' : (t.nom_insee ?? t.nom_cadastre ?? '')
      return texte ? { x: g.X(sx), y: g.Y(sy), texte } : null
    })
    .filter((e): e is { x: number; y: number; texte: string } => e !== null)
})

defineExpose({ survole })
</script>

<template>
  <div
    v-if="geo"
    class="relative overflow-hidden rounded border"
    :style="{ background: 'var(--plan)', borderColor: 'var(--ui-border)' }"
  >
    <svg
      :viewBox="`0 0 ${W} ${geo.H}`"
      class="block h-auto w-full"
      role="img"
      :aria-label="`Découpage de ${nom} en ${territoires.length} territoires cadastraux historiques`"
    >
      <path
        v-for="c in chemins"
        :key="c.i"
        :d="c.d"
        :fill="teinte(c.t)"
        fill-rule="evenodd"
        :stroke="survole === c.i ? 'var(--ui-text)' : 'var(--plan)'"
        :stroke-width="survole === c.i ? 1.4 : 0.7"
        :opacity="survole === null || survole === c.i ? 1 : 0.28"
        class="cursor-pointer transition-opacity duration-100"
        tabindex="0"
        @mouseenter="survole = c.i"
        @mouseleave="survole = null"
        @focus="survole = c.i"
        @blur="survole = null"
      >
        <title>
          {{ libelle(c.t) }}{{ c.t.code ? ` (${c.t.code})` : '' }}{{ c.t.km2 ? ` — ${c.t.km2} km²` : '' }}
        </title>
      </path>

      <text
        v-for="(e, i) in etiquettes"
        :key="i"
        :x="e.x"
        :y="e.y"
        text-anchor="middle"
        font-family="var(--font-mono)"
        font-size="9.5"
        fill="var(--ui-text)"
        paint-order="stroke"
        :stroke="'var(--plan)'"
        stroke-width="2.4"
        stroke-linejoin="round"
        class="pointer-events-none"
      >
        {{ e.texte }}
      </text>
    </svg>

    <div
      v-if="survole !== null"
      class="pointer-events-none absolute left-3 top-3 max-w-[260px] rounded border px-3 py-2 text-sm shadow-lg"
      :style="{ background: 'var(--ui-bg-elevated)', borderColor: 'var(--ui-border)' }"
    >
      <div
        v-if="territoires[survole]!.code"
        class="font-mono text-xs text-cadastre-500 dark:text-cadastre-400"
      >
        {{ territoires[survole]!.code }}
      </div>
      <div>{{ libelle(territoires[survole]!) }}</div>
      <div class="mt-0.5 font-mono text-xs" :style="{ color: 'var(--ui-text-dimmed)' }">
        {{ territoires[survole]!.km2 ?? '?' }} km²
        <template v-if="territoires[survole]!.fusion_le">
          · fusion {{ territoires[survole]!.fusion_le }}
        </template>
        <template v-else-if="territoires[survole]!.nature === 'absorbee'">· fusion ancienne</template>
      </div>
    </div>
  </div>

  <p v-else class="text-sm" :style="{ color: 'var(--ui-text-dimmed)' }">
    Aucune géométrie de section disponible pour cette commune.
  </p>
</template>
