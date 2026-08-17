<script setup lang="ts">
/**
 * Frise parcellaire d'une commune : un curseur, et le parcellaire se rejoue.
 *
 * Tout l'historique est chargé en une fois (voir server/api/communes/[code]/
 * parcelles.get.ts). Déplacer le curseur ne déclenche donc aucune requête : on
 * ne change que des FILTRES MapLibre, ce qui se joue dans le GPU et reste fluide
 * même en balayant vite. C'est ce qui fait la différence entre une frise qu'on
 * manipule et une frise qu'on subit.
 *
 * Chaque entité porte les deux relevés entre lesquels elle a existé, exprimés en
 * indices. Une parcelle est visible au pas `i` si debut <= i <= fin.
 */
import type {
  Map as MapLibreMap,
  GeoJSONSource,
  FilterSpecification,
  StyleSpecification,
} from 'maplibre-gl'
import type { FeatureCollection } from 'geojson'

const props = defineProps<{
  code: string
  millesimes: string[]
  parcelles: FeatureCollection
}>()

const conteneur = ref<HTMLDivElement | null>(null)
const carte = shallowRef<MapLibreMap | null>(null)
const pret = ref(false)

/** Position sur la frise, en indice de relevé. On ouvre sur le plus récent. */
const pas = ref(props.millesimes.length - 1)
const anime = ref(false)
let minuteur: ReturnType<typeof setInterval> | null = null

const dernier = computed(() => props.millesimes.length - 1)
const millesimeCourant = computed(() => props.millesimes[pas.value] ?? '')

/**
 * Un jalon par année, placé à la position du PREMIER relevé de cette année.
 * Le curseur avance par relevé, pas par jour : répartir les années à intervalles
 * réguliers donnerait une réglette qui ne correspond à rien.
 */
const jalons = computed(() => {
  const vues = new Set<string>()
  const out: { annee: string; position: number }[] = []
  const n = Math.max(1, props.millesimes.length - 1)
  props.millesimes.forEach((m, i) => {
    const annee = m.slice(0, 4)
    if (vues.has(annee)) return
    vues.add(annee)
    out.push({ annee, position: (i / n) * 100 })
  })
  // Au-delà d'une dizaine de jalons les libellés se chevauchent : on n'en garde
  // qu'un sur deux plutôt que de les laisser se marcher dessus.
  return out.length > 6 ? out.filter((_, i) => i % 2 === 0) : out
})

const dateLisible = (iso: string) =>
  new Date(iso).toLocaleDateString('fr-FR', { day: 'numeric', month: 'long', year: 'numeric' })

/**
 * `fin` vaut null tant que la parcelle est toujours là : on le remplace par le
 * dernier indice pour que la comparaison numérique fonctionne dans le filtre.
 */
const finEffective = ['coalesce', ['get', 'fin'], dernier.value] as unknown as FilterSpecification

/** Présente au pas courant. */
function filtrePresente(i: number): FilterSpecification {
  return ['all', ['<=', ['get', 'debut'], i], ['>=', finEffective, i]] as FilterSpecification
}

/** Apparue à ce relevé — première version d'une parcelle jusqu'ici inconnue. */
function filtreApparue(i: number): FilterSpecification {
  // Au tout premier relevé, TOUT est « nouveau » : c'est notre fenêtre qui
  // s'ouvre, pas le cadastre qui se crée. On n'affiche donc rien.
  if (i === 0) return ['==', ['get', 'debut'], -1] as FilterSpecification
  return ['all', ['==', ['get', 'debut'], i], ['==', ['get', 'premiere'], true]] as FilterSpecification
}

/** Redessinée à ce relevé : la parcelle existait déjà, son tracé a changé. */
function filtreRemaniee(i: number): FilterSpecification {
  return ['all', ['==', ['get', 'debut'], i], ['==', ['get', 'premiere'], false]] as FilterSpecification
}

/** Disparue entre le relevé précédent et celui-ci — affichée en fantôme. */
function filtreDisparue(i: number): FilterSpecification {
  if (i === 0) return ['==', ['get', 'debut'], -1] as FilterSpecification
  return ['all', ['==', finEffective, i - 1], ['==', ['get', 'derniere'], true]] as FilterSpecification
}

/** Décompte des entités correspondant à un filtre, calculé sur la donnée brute. */
function compter(test: (p: Record<string, unknown>) => boolean): number {
  let n = 0
  for (const f of props.parcelles.features) if (f.properties && test(f.properties)) n++
  return n
}

/**
 * Surface et effectif à CHAQUE relevé, calculés une seule fois au montage.
 *
 * Le calcul est trivial mais il porte sur des milliers d'entités : le refaire à
 * chaque mouvement du curseur rendrait le balayage saccadé, alors qu'une passe
 * unique suffit — les bornes de chaque version sont connues d'avance.
 */
const serie = computed(() => {
  const n = props.millesimes.length
  const surface = new Array<number>(n).fill(0)
  const effectif = new Array<number>(n).fill(0)

  for (const f of props.parcelles.features) {
    const p = f.properties
    if (!p) continue
    const debut = p.debut as number
    const fin = (p.fin as number | null) ?? n - 1
    const s = (p.surface as number | null) ?? 0
    for (let i = debut; i <= fin && i < n; i++) {
      surface[i]! += s
      effectif[i]! += 1
    }
  }
  return { surface, effectif }
})

const surfaceCourante = computed(() => serie.value.surface[pas.value] ?? 0)
const surfacePrecedente = computed(() =>
  pas.value > 0 ? (serie.value.surface[pas.value - 1] ?? 0) : null,
)
const variationSurface = computed(() =>
  surfacePrecedente.value == null ? null : surfaceCourante.value - surfacePrecedente.value,
)

const hectares = (m2: number) =>
  m2 >= 1e6 ? `${(m2 / 1e6).toFixed(2)} km²` : `${(m2 / 1e4).toFixed(1)} ha`

const signe = (m2: number) => {
  const ha = m2 / 1e4
  const v = Math.abs(ha) >= 10 ? ha.toFixed(0) : ha.toFixed(2)
  return `${ha >= 0 ? '+' : '−'}${v.replace('-', '')} ha`
}

/**
 * Courbe de la surface totale, en coordonnées normalisées.
 *
 * L'échelle verticale est bornée aux valeurs réellement observées, pas à zéro :
 * la surface d'une commune varie de quelques pour mille d'un relevé à l'autre, et
 * une échelle partant de zéro afficherait une ligne parfaitement plate. On montre
 * donc la VARIATION, ce qui suppose de le dire — l'axe est légendé.
 */
const courbe = computed(() => {
  const s = serie.value.surface
  if (s.length < 2) return null
  const min = Math.min(...s)
  const max = Math.max(...s)
  const amplitude = max - min || 1
  const pts = s.map((v, i) => {
    const x = (i / (s.length - 1)) * 100
    const y = 100 - ((v - min) / amplitude) * 100
    return { x, y }
  })
  return {
    min,
    max,
    d: pts.map((p, i) => `${i === 0 ? 'M' : 'L'} ${p.x.toFixed(2)} ${p.y.toFixed(2)}`).join(' '),
    aire:
      `M 0 100 ` +
      pts.map((p) => `L ${p.x.toFixed(2)} ${p.y.toFixed(2)}`).join(' ') +
      ` L 100 100 Z`,
    pts,
  }
})

const i = computed(() => pas.value)
const nPresentes = computed(() =>
  compter((p) => (p.debut as number) <= i.value && ((p.fin as number | null) ?? dernier.value) >= i.value),
)
const nApparues = computed(() =>
  i.value === 0 ? 0 : compter((p) => p.debut === i.value && p.premiere === true),
)
const nRemaniees = computed(() => compter((p) => p.debut === i.value && p.premiere === false))
const nDisparues = computed(() =>
  i.value === 0
    ? 0
    : compter((p) => (((p.fin as number | null) ?? dernier.value) === i.value - 1) && p.derniere === true),
)

/** Emprise des parcelles, pour cadrer la carte au montage. */
function emprise(): [[number, number], [number, number]] | null {
  let x1 = 180, y1 = 90, x2 = -180, y2 = -90
  let vu = false
  for (const f of props.parcelles.features) {
    const g = f.geometry
    if (g.type !== 'MultiPolygon' && g.type !== 'Polygon') continue
    const anneaux = g.type === 'MultiPolygon' ? g.coordinates.flat() : g.coordinates
    for (const anneau of anneaux) {
      for (const [x, y] of anneau as [number, number][]) {
        if (x < x1) x1 = x
        if (y < y1) y1 = y
        if (x > x2) x2 = x
        if (y > y2) y2 = y
        vu = true
      }
    }
  }
  return vu ? [[x1, y1], [x2, y2]] : null
}

function appliquerFiltres() {
  const m = carte.value
  if (!m || !pret.value) return
  const n = pas.value
  m.setFilter('parcelles-fond', filtrePresente(n))
  m.setFilter('parcelles-contour', filtrePresente(n))
  m.setFilter('parcelles-apparues', filtreApparue(n))
  m.setFilter('parcelles-remaniees', filtreRemaniee(n))
  m.setFilter('parcelles-disparues', filtreDisparue(n))
  m.setFilter('parcelles-disparues-contour', filtreDisparue(n))
}

watch(pas, appliquerFiltres)

function basculerAnimation() {
  if (anime.value) return arreter()
  anime.value = true
  // On repart du début si on est déjà au bout, sinon le bouton semblerait inerte.
  if (pas.value >= dernier.value) pas.value = 0
  minuteur = setInterval(() => {
    if (pas.value >= dernier.value) return arreter()
    pas.value++
  }, 750)
}

function arreter() {
  anime.value = false
  if (minuteur) clearInterval(minuteur)
  minuteur = null
}

onMounted(async () => {
  // MapLibre touche au DOM : import dynamique, jamais évalué en SSR.
  // La v6 n'expose pas d'export par défaut.
  const { Map: CarteGL, NavigationControl } = await import('maplibre-gl')
  if (!conteneur.value) return

  const m = new CarteGL({
    container: conteneur.value,
    style: {
      version: 8 as const,
      sources: {
        parcelles: { type: 'geojson', data: props.parcelles as never },
      },
      // Pas de layer `background` : le canvas reste transparent et laisse voir
      // le fond CSS du conteneur, qui suit donc le thème clair/sombre.
      layers: [
        {
          id: 'parcelles-fond',
          type: 'fill',
          source: 'parcelles',
          paint: { 'fill-color': '#8fa3a6', 'fill-opacity': 0.18 },
        },
        {
          id: 'parcelles-contour',
          type: 'line',
          source: 'parcelles',
          paint: {
            'line-color': '#6f7a80',
            'line-width': ['interpolate', ['linear'], ['zoom'], 11, 0.3, 16, 0.9],
            'line-opacity': 0.7,
          },
        },
        {
          // Fantôme de ce qui vient de disparaître : on le montre APRÈS coup,
          // au relevé où l'on constate l'absence. Sans ça, une disparition ne
          // se lit que comme un trou, et le regard ne l'attrape pas.
          id: 'parcelles-disparues',
          type: 'fill',
          source: 'parcelles',
          paint: { 'fill-color': '#ac4227', 'fill-opacity': 0.22 },
        },
        {
          id: 'parcelles-disparues-contour',
          type: 'line',
          source: 'parcelles',
          paint: { 'line-color': '#ac4227', 'line-width': 1.4, 'line-dasharray': [2, 1.5] },
        },
        {
          id: 'parcelles-remaniees',
          type: 'fill',
          source: 'parcelles',
          paint: { 'fill-color': '#b8933a', 'fill-opacity': 0.55 },
        },
        {
          id: 'parcelles-apparues',
          type: 'fill',
          source: 'parcelles',
          paint: { 'fill-color': '#1d6b6f', 'fill-opacity': 0.6 },
        },
      ],
    } satisfies StyleSpecification,
    center: [6.2, 49.0],
    zoom: 11,
    attributionControl: false,
  })

  m.addControl(new NavigationControl({ showCompass: false }), 'top-right')

  m.on('load', () => {
    carte.value = m
    pret.value = true
    const bbox = emprise()
    if (bbox) m.fitBounds(bbox, { padding: 24, duration: 0 })
    appliquerFiltres()
  })

  // Infobulle : la couche `symbol` de MapLibre exigerait une source de glyphes
  // distante. On reste autonome avec du HTML.
  m.on('click', 'parcelles-fond', (e) => {
    const f = e.features?.[0]
    if (!f?.properties) return
    survol.value = {
      id: String(f.properties.id),
      section: String(f.properties.section),
      numero: String(f.properties.numero),
      contenance: f.properties.contenance as number | null,
      debut: f.properties.debut as number,
      fin: f.properties.fin as number | null,
    }
  })
  m.on('mouseenter', 'parcelles-fond', () => (m.getCanvas().style.cursor = 'pointer'))
  m.on('mouseleave', 'parcelles-fond', () => (m.getCanvas().style.cursor = ''))
})

const survol = ref<{
  id: string
  section: string
  numero: string
  contenance: number | null
  debut: number
  fin: number | null
} | null>(null)

// La source ne change pas d'identité entre deux communes, mais son contenu si :
// sans ce watch, naviguer d'une commune à l'autre garderait l'ancien parcellaire.
watch(
  () => props.parcelles,
  (nouvelles) => {
    const m = carte.value
    if (!m || !pret.value) return
    ;(m.getSource('parcelles') as GeoJSONSource | undefined)?.setData(nouvelles as never)
    const bbox = emprise()
    if (bbox) m.fitBounds(bbox, { padding: 24, duration: 400 })
    pas.value = dernier.value
    appliquerFiltres()
  },
)

onBeforeUnmount(() => {
  arreter()
  carte.value?.remove()
})

const surface = (m2: number | null) =>
  m2 == null ? '—' : m2 >= 10000 ? `${(m2 / 10000).toFixed(2)} ha` : `${m2.toLocaleString('fr-FR')} m²`
</script>

<template>
  <div class="flex flex-col gap-3">
    <div class="relative overflow-hidden rounded-lg border border-default bg-elevated">
      <div ref="conteneur" class="h-[520px] w-full" />

      <div
        v-if="survol"
        class="absolute left-3 top-3 max-w-[15rem] rounded-md border border-default bg-default/95 p-3 text-xs shadow-lg backdrop-blur"
      >
        <div class="font-mono text-sm font-semibold">
          {{ survol.section }} {{ survol.numero }}
        </div>
        <dl class="mt-2 space-y-1 text-muted">
          <div class="flex justify-between gap-3">
            <dt>Contenance</dt>
            <dd class="font-mono text-default">{{ surface(survol.contenance) }}</dd>
          </div>
          <div class="flex justify-between gap-3">
            <dt>Vue depuis</dt>
            <dd class="font-mono text-default">{{ millesimes[survol.debut]?.slice(0, 4) }}</dd>
          </div>
          <div class="flex justify-between gap-3">
            <dt>Jusqu'à</dt>
            <dd class="font-mono text-default">
              {{ survol.fin == null ? 'aujourd’hui' : millesimes[survol.fin]?.slice(0, 4) }}
            </dd>
          </div>
        </dl>
        <p class="mt-2 font-mono text-[0.65rem] text-dimmed">{{ survol.id }}</p>
        <div class="mt-2 flex items-center gap-1">
          <UButton
            :to="`/parcelle/${survol.id}`"
            size="xs"
            variant="subtle"
            color="neutral"
            trailing-icon="i-lucide-arrow-right"
          >Sa filiation</UButton>
          <UButton size="xs" variant="ghost" @click="survol = null">Fermer</UButton>
        </div>
      </div>
    </div>

    <!-- Frise -->
    <div class="rounded-lg border border-default bg-elevated p-4">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div class="flex items-center gap-3">
          <UButton
            :icon="anime ? 'i-lucide-pause' : 'i-lucide-play'"
            size="sm"
            color="neutral"
            variant="subtle"
            :aria-label="anime ? 'Interrompre' : 'Rejouer l’évolution'"
            @click="basculerAnimation"
          />
          <div>
            <div class="text-lg font-semibold tabular-nums">{{ dateLisible(millesimeCourant) }}</div>
            <div class="text-xs text-muted">
              relevé {{ pas + 1 }} sur {{ millesimes.length }}
            </div>
          </div>
        </div>

        <dl class="flex flex-wrap items-center gap-x-5 gap-y-1 text-sm">
          <div class="flex items-center gap-1.5">
            <dt class="text-muted">Parcelles</dt>
            <dd class="font-mono font-semibold tabular-nums">{{ nPresentes.toLocaleString('fr-FR') }}</dd>
          </div>
          <div class="flex items-center gap-1.5">
            <dt class="text-muted">Superficie</dt>
            <dd class="font-mono font-semibold tabular-nums">{{ hectares(surfaceCourante) }}</dd>
            <dd
              v-if="variationSurface"
              class="font-mono text-xs tabular-nums"
              :class="variationSurface > 0 ? 'text-cadastre-600 dark:text-cadastre-400' : 'text-ecart-600 dark:text-ecart-400'"
            >{{ signe(variationSurface) }}</dd>
          </div>
          <div v-if="nApparues" class="flex items-center gap-1.5">
            <span class="size-2.5 rounded-sm bg-cadastre-500" />
            <dt class="text-muted">apparues</dt>
            <dd class="font-mono font-semibold tabular-nums">{{ nApparues }}</dd>
          </div>
          <div v-if="nRemaniees" class="flex items-center gap-1.5">
            <span class="size-2.5 rounded-sm bg-insee-400" />
            <dt class="text-muted">redessinées</dt>
            <dd class="font-mono font-semibold tabular-nums">{{ nRemaniees }}</dd>
          </div>
          <div v-if="nDisparues" class="flex items-center gap-1.5">
            <span class="size-2.5 rounded-sm bg-ecart-500" />
            <dt class="text-muted">disparues</dt>
            <dd class="font-mono font-semibold tabular-nums">{{ nDisparues }}</dd>
          </div>
        </dl>
      </div>

      <!-- Courbe de la superficie totale, alignée sur le curseur.
           L'échelle verticale est bornée aux valeurs observées et NON à zéro : la
           superficie d'une commune varie de quelques pour mille d'un relevé à
           l'autre, et partir de zéro donnerait une ligne rigoureusement plate. On
           montre donc l'amplitude réelle, et on l'écrit en toutes lettres. -->
      <div v-if="courbe" class="relative mt-4">
        <svg
          viewBox="0 0 100 100"
          preserveAspectRatio="none"
          class="h-16 w-full"
          role="img"
          :aria-label="`Superficie totale, de ${hectares(courbe.min)} à ${hectares(courbe.max)}`"
        >
          <path :d="courbe.aire" fill="var(--color-cadastre-500)" opacity="0.12" />
          <path
            :d="courbe.d"
            fill="none"
            stroke="var(--color-cadastre-500)"
            stroke-width="1.5"
            vector-effect="non-scaling-stroke"
          />
          <line
            :x1="courbe.pts[pas]?.x ?? 0"
            y1="0"
            :x2="courbe.pts[pas]?.x ?? 0"
            y2="100"
            stroke="currentColor"
            stroke-width="1"
            opacity="0.35"
            vector-effect="non-scaling-stroke"
          />
        </svg>
        <div class="mt-0.5 flex justify-between font-mono text-[0.65rem] text-dimmed">
          <span>{{ hectares(courbe.min) }}</span>
          <span class="text-muted">superficie totale — amplitude sur la période</span>
          <span>{{ hectares(courbe.max) }}</span>
        </div>
      </div>

      <input
        v-model.number="pas"
        type="range"
        :min="0"
        :max="dernier"
        step="1"
        class="mt-4 w-full accent-cadastre-500"
        :aria-label="`Relevé : ${millesimeCourant}`"
        @mousedown="arreter"
        @touchstart="arreter"
      />

      <!-- Repères d'années : un jalon par année, pas par relevé — quatre relevés
           annuels donneraient une réglette illisible.
           Positionnés sur l'INDICE du premier relevé de chaque année, et non
           répartis à intervalles réguliers : les relevés ne sont pas également
           espacés dans le temps, un affichage régulier mentirait sur la
           chronologie. -->
      <div class="relative mt-1 h-4 font-mono text-[0.65rem] text-dimmed">
        <span
          v-for="j in jalons"
          :key="j.annee"
          class="absolute -translate-x-1/2"
          :style="{ left: `${j.position}%` }"
        >{{ j.annee }}</span>
      </div>
    </div>
  </div>
</template>
