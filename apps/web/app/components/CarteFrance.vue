<script setup lang="ts">
/**
 * Carte de France interactive, alimentée par nos propres tuiles vectorielles.
 *
 * Pas de fond de carte tiers : les contours cadastraux sont plus fins que
 * n'importe quelle tuile raster, et un fond OSM ajouterait du bruit visuel sans
 * rien apprendre. La carte EST la donnée.
 *
 * Pas de couche `symbol` non plus : les libellés MapLibre exigent une source de
 * glyphes, donc un CDN. Les noms passent par une infobulle HTML, ce qui garde
 * l'application autonome.
 *
 * Le remplissage encode le nombre de communes absorbées — l'information qui
 * donne envie de cliquer, et le cœur du sujet.
 */
import type {
  Map as MapLibreMap,
  MapMouseEvent,
  MapGeoJSONFeature,
  ExpressionSpecification,
  StyleSpecification,
} from 'maplibre-gl'

const props = withDefaults(
  defineProps<{
    /** Recadre sur ce département au montage (code INSEE à 2 ou 3 caractères). */
    departement?: string | null
    /** Commune mise en évidence. */
    selection?: string | null
    /** Emprise à cadrer, en degrés : [ouest, sud, est, nord]. */
    emprise?: [number, number, number, number] | null
  }>(),
  { departement: null, selection: null, emprise: null },
)

const emit = defineEmits<{
  selectionner: [code: string]
  survoler: [info: { code: string; nom: string; absorbees: number } | null]
}>()

const conteneur = ref<HTMLDivElement | null>(null)
const carte = shallowRef<MapLibreMap | null>(null)
const pret = ref(false)
const echec = ref<string | null>(null)
const survol = ref<{ code: string; nom: string; absorbees: number; x: number; y: number } | null>(
  null,
)
/** Au-delà de z8 la carte montre les communes : la légende doit suivre. */
const echelleCommunes = ref(false)

/**
 * Sonde de diagnostic, activée par ?debug=1. Elle publie l'état interne de
 * MapLibre dans le DOM, seul moyen de l'observer depuis un navigateur headless
 * — la console n'est pas accessible et les erreurs de tuile sont silencieuses.
 */
const debogage = ref<string[]>([])
const trace = (m: string) => {
  if (debogage.value.length < 40) debogage.value.push(m)
}

/**
 * Rampe des départements. Ils agrègent les absorptions de leurs communes, donc
 * l'échelle est sans rapport avec celle des communes : médiane 26, p90 62,
 * maximum 205.
 */
/**
 * Emprise d'ouverture, cartouches d'outre-mer compris.
 *
 * Les DROM ne sont pas à leur position géographique sur cette carte : ils sont
 * translatés dans une colonne à l'ouest de l'Hexagone (migration 060), selon la
 * convention cartographique française. À l'échelle, sans redimensionnement.
 */
const EMPRISE_FRANCE: [number, number, number, number] = [-13.8, 40.8, 9.8, 51.4]

const RAMPE_DEP: ExpressionSpecification = [
  'interpolate',
  ['linear'],
  ['coalesce', ['get', 'nb_absorbees'], 0],
  0, '#f2f5f5',
  10, '#d3e3e3',
  25, '#aecccd',
  45, '#82b0b2',
  70, '#4f8f92',
  110, '#1d6b6f',
]

/** Rampe séquentielle sur le nombre d'absorptions, du plus pâle au plus dense. */
const RAMPE_FILL: ExpressionSpecification = [
  'interpolate',
  ['linear'],
  ['coalesce', ['get', 'nb_absorbees'], 0],
  0, '#ffffff',
  1, '#cfe0e0',
  3, '#a3c6c7',
  6, '#71a9ab',
  10, '#428a8d',
  16, '#1d6b6f',
]

onMounted(async () => {
  // Import dynamique : MapLibre touche au DOM et ne peut pas être évalué en SSR.
  // maplibre-gl v6 n'expose pas d'export par défaut : on prend les classes nommées.
  // La feuille de style, elle, est chargée statiquement via nuxt.config.
  const { Map: CarteGL, NavigationControl, AttributionControl } = await import('maplibre-gl')

  if (!conteneur.value) return

  const m = new CarteGL({
    container: conteneur.value,
    // Style entièrement local, servi depuis nos tuiles.
    style: {
      version: 8 as const,
      sources: {
        nexus: {
          type: 'vector',
          tiles: [`${window.location.origin}/api/tiles/{z}/{x}/{y}`],
          minzoom: 0,
          // Plafonner trop bas fait suragrandir la dernière tuile au lieu d'en
          // demander de nouvelles : la simplification devient alors visible.
          maxzoom: 15,
        },
      },
      // Pas de layer `background` : sans lui, le canvas est transparent et laisse
      // voir le fond CSS du conteneur, donc la couleur de plan suit le thème.
      layers: [
        {
          id: 'departements-fill',
          type: 'fill',
          source: 'nexus',
          'source-layer': 'departements',
          maxzoom: 9,
          paint: { 'fill-color': RAMPE_DEP, 'fill-opacity': 0.95 },
        },
        {
          id: 'communes-fill',
          type: 'fill',
          source: 'nexus',
          'source-layer': 'communes',
          minzoom: 8,
          paint: {
            'fill-color': RAMPE_FILL,
            'fill-opacity': ['interpolate', ['linear'], ['zoom'], 8, 0.55, 9.5, 0.9],
          },
        },
        {
          id: 'communes-ligne',
          type: 'line',
          source: 'nexus',
          'source-layer': 'communes',
          minzoom: 8,
          paint: {
            'line-color': '#6f7a80',
            'line-width': ['interpolate', ['linear'], ['zoom'], 8, 0.2, 12, 0.7],
            'line-opacity': 0.45,
          },
        },
        {
          // Trait départemental, présent à tous les zooms : c'est le repère qui
          // évite de se perdre une fois descendu au niveau des communes.
          id: 'limites-departements',
          type: 'line',
          source: 'nexus',
          'source-layer': 'limites_departements',
          paint: {
            'line-color': '#4d565c',
            'line-width': ['interpolate', ['linear'], ['zoom'], 4, 0.8, 8, 1.4, 12, 2.2],
            'line-opacity': ['interpolate', ['linear'], ['zoom'], 4, 0.55, 9, 0.8],
          },
        },
        {
          // Trait régional, plus appuyé : la hiérarchie se lit à l'épaisseur.
          id: 'limites-regions',
          type: 'line',
          source: 'nexus',
          'source-layer': 'limites_regions',
          paint: {
            'line-color': '#15191c',
            'line-width': ['interpolate', ['linear'], ['zoom'], 4, 1.2, 8, 2.2, 12, 3.2],
            'line-opacity': 0.75,
          },
        },
        {
          id: 'commune-survol',
          type: 'line',
          source: 'nexus',
          'source-layer': 'communes',
          minzoom: 8,
          paint: { 'line-color': '#ac4227', 'line-width': 2.2 },
          filter: ['==', ['get', 'code_insee'], ''],
        },
        {
          id: 'commune-selection',
          type: 'line',
          source: 'nexus',
          'source-layer': 'communes',
          minzoom: 8,
          paint: { 'line-color': '#15191c', 'line-width': 2.8 },
          filter: ['==', ['get', 'code_insee'], ''],
        },
      ],
    } satisfies StyleSpecification,
    // Position de repli : le cadrage réel est fait au chargement par fitBounds
    // sur EMPRISE_FRANCE, qui englobe aussi les cartouches d'outre-mer.
    center: [-2.0, 46.5],
    zoom: 4.4,
    attributionControl: false,
  })

  m.addControl(new NavigationControl({ showCompass: false }), 'top-right')
  m.addControl(
    new AttributionControl({
      compact: true,
      customAttribution: 'Cadastre Etalab · COG INSEE',
    }),
    'bottom-right',
  )

  const communeSous = (e: MapMouseEvent): MapGeoJSONFeature | undefined =>
    m.queryRenderedFeatures(e.point, { layers: ['communes-fill'] })[0]

  m.on('mousemove', (e: MapMouseEvent) => {
    const f = communeSous(e)
    if (!f) {
      if (survol.value) {
        survol.value = null
        m.setFilter('commune-survol', ['==', ['get', 'code_insee'], ''])
        emit('survoler', null)
      }
      m.getCanvas().style.cursor = ''
      return
    }
    const info = {
      code: String(f.properties.code_insee),
      nom: String(f.properties.nom),
      absorbees: Number(f.properties.nb_absorbees ?? 0),
    }
    survol.value = { ...info, x: e.point.x, y: e.point.y }
    m.setFilter('commune-survol', ['==', ['get', 'code_insee'], info.code])
    m.getCanvas().style.cursor = 'pointer'
    emit('survoler', info)
  })

  m.on('zoom', () => {
    echelleCommunes.value = m.getZoom() >= 8
  })

  m.on('mouseout', () => {
    survol.value = null
    m.setFilter('commune-survol', ['==', ['get', 'code_insee'], ''])
    emit('survoler', null)
  })

  m.on('click', (e: MapMouseEvent) => {
    const f = communeSous(e)
    if (f) return emit('selectionner', String(f.properties.code_insee))
    // Sous le zoom des communes, un clic sur un département y plonge : c'est le
    // geste naturel avant que les communes n'apparaissent.
    const d = m.queryRenderedFeatures(e.point, { layers: ['departements-fill'] })[0]
    if (d) m.easeTo({ center: e.lngLat, zoom: Math.max(m.getZoom() + 2.2, 8.2), duration: 700 })
  })

  // Ne pas dépendre du seul événement `load` : avec un style inline il peut
  // être émis avant que le composant n'ait fini de s'abonner, et l'écran de
  // chargement resterait alors indéfiniment par-dessus une carte pourtant
  // fonctionnelle. On teste donc l'état courant, et on écoute plusieurs signaux.
  const marquerPret = () => {
    if (pret.value) return
    pret.value = true
    appliquerSelection()
    appliquerEmprise()
  }
  if (m.loaded()) marquerPret()
  m.once('load', marquerPret)
  m.once('idle', marquerPret)
  // Filet de sécurité : même si aucun signal n'arrive (tuiles injoignables,
  // rendu logiciel très lent), on découvre la carte plutôt que de la cacher.
  const secours = setTimeout(marquerPret, 4000)
  m.once('remove', () => clearTimeout(secours))

  // Sans ça, une tuile en erreur ou un style invalide laisse un écran de
  // chargement éternel, sans le moindre indice.
  m.on('error', (e) => {
    const msg = e.error?.message ?? 'erreur inconnue'
    console.error('[carte]', e.error)
    trace('ERREUR ' + msg)
    if (!pret.value) echec.value = msg
  })

  // Sonde : l'état des sources n'est observable autrement qu'en le publiant.
  m.on('sourcedata', (e) => {
    if (e.sourceId === 'nexus') {
      trace(`sourcedata chargée=${e.isSourceLoaded} tuile=${e.tile ? 'oui' : 'non'}`)
    }
  })
  m.on('idle', () => {
    trace(`idle zoom=${m.getZoom().toFixed(2)}`)
    trace('rendus dep=' + m.queryRenderedFeatures({ layers: ['departements-fill'] }).length)
    trace('rendus com=' + m.queryRenderedFeatures({ layers: ['communes-fill'] }).length)
  })

  carte.value = m
})

onBeforeUnmount(() => carte.value?.remove())

function appliquerSelection() {
  const m = carte.value
  if (!m || !pret.value) return
  m.setFilter('commune-selection', ['==', ['get', 'code_insee'], props.selection ?? ''])
}

watch(() => props.selection, appliquerSelection)

/**
 * Recadre la vue. Appelée avant que la carte ne soit prête, fitBounds serait
 * perdu : on mémorise alors l'emprise et on l'applique au premier signal.
 */
let empriseEnAttente: [number, number, number, number] | null = null

function cadrer(bbox: [number, number, number, number], anime = true) {
  const m = carte.value
  if (!m || !pret.value) {
    empriseEnAttente = bbox
    return
  }
  m.fitBounds(bbox, { padding: 36, duration: anime ? 700 : 0 })
}

function appliquerEmprise() {
  const b = props.emprise ?? empriseEnAttente ?? EMPRISE_FRANCE
  empriseEnAttente = null
  cadrer(b, false)
}

watch(() => props.emprise, (b) => b && cadrer(b))

defineExpose({ cadrer })
</script>

<template>
  <div class="relative h-full w-full">
    <div ref="conteneur" class="h-full w-full" :style="{ background: 'var(--plan)' }" />

    <!-- Infobulle HTML : évite d'avoir à charger des glyphes depuis un CDN. -->
    <div
      v-if="survol"
      class="pointer-events-none absolute z-10 max-w-[220px] rounded border px-2.5 py-1.5 text-sm shadow-lg"
      :style="{
        background: 'var(--ui-bg-elevated)',
        borderColor: 'var(--ui-border)',
        left: `${Math.min(survol.x + 14, 9999)}px`,
        top: `${Math.max(survol.y - 46, 8)}px`,
      }"
    >
      <div class="font-mono text-xs text-cadastre-500 dark:text-cadastre-400">{{ survol.code }}</div>
      <div class="leading-tight">{{ survol.nom }}</div>
      <div
        v-if="survol.absorbees"
        class="font-mono text-xs"
        :style="{ color: 'var(--color-ecart-500)' }"
      >
        {{ survol.absorbees }} commune{{ survol.absorbees > 1 ? 's' : '' }} absorbée{{
          survol.absorbees > 1 ? 's' : ''
        }}
      </div>
    </div>

    <!-- Légende de la rampe -->
    <div
      class="absolute bottom-3 left-3 z-10 rounded border px-2.5 py-2 text-xs shadow"
      :style="{ background: 'var(--ui-bg-elevated)', borderColor: 'var(--ui-border)' }"
    >
      <div class="eyebrow mb-1.5">Communes disparues absorbées</div>
      <div class="flex items-center gap-1">
        <i
          v-for="(c, i) in echelleCommunes
            ? ['#ffffff', '#cfe0e0', '#a3c6c7', '#71a9ab', '#428a8d', '#1d6b6f']
            : ['#f2f5f5', '#d3e3e3', '#aecccd', '#82b0b2', '#4f8f92', '#1d6b6f']"
          :key="i"
          class="inline-block h-3 w-5"
          :style="{ background: c }"
        />
      </div>
      <div class="mt-1 flex justify-between font-mono" :style="{ color: 'var(--ui-text-dimmed)' }">
        <span>0</span><span>{{ echelleCommunes ? '16+' : '110+' }}</span>
      </div>
      <div class="mt-1" :style="{ color: 'var(--ui-text-dimmed)' }">
        {{ echelleCommunes ? 'par commune' : 'par département — zoomez pour les communes' }}
      </div>
    </div>

    <div
      v-if="$route.query.debug"
      id="carte-debug"
      class="absolute right-2 top-24 z-30 max-h-[70vh] overflow-auto rounded border bg-white p-2 font-mono text-[10px] text-black"
    >
      <div v-for="(l, i) in debogage" :key="i">{{ l }}</div>
    </div>

    <div
      v-if="!pret"
      class="pointer-events-none absolute inset-0 z-20 flex items-center justify-center px-6 text-center text-sm"
      :style="{ background: 'var(--plan)', color: 'var(--ui-text-dimmed)' }"
    >
      <span v-if="echec" :style="{ color: 'var(--color-ecart-500)' }">
        La carte n'a pas pu se charger : {{ echec }}
      </span>
      <span v-else>Chargement de la carte…</span>
    </div>
  </div>
</template>

<style>
/* Les contrôles MapLibre sont neutres par défaut : on les aligne sur la charte. */
.maplibregl-ctrl-group {
  background: var(--ui-bg-elevated) !important;
  border: 1px solid var(--ui-border) !important;
  box-shadow: none !important;
}
.maplibregl-ctrl-group button + button {
  border-top: 1px solid var(--ui-border) !important;
}
.maplibregl-ctrl-attrib {
  background: var(--ui-bg-elevated) !important;
  color: var(--ui-text-dimmed) !important;
  font-size: 11px !important;
}
.maplibregl-ctrl-attrib a {
  color: var(--ui-text-muted) !important;
}
</style>
