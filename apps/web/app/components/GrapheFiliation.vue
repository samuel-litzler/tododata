<script setup lang="ts">
/**
 * Graphe de filiation d'une parcelle : ses ascendants à gauche, ses descendants
 * à droite, la parcelle consultée au centre.
 *
 * Rendu en SVG pur, sans bibliothèque de graphes. Le graphe est un arbre à
 * générations : la position d'un nœud est entièrement déterminée par sa distance
 * à la parcelle consultée. Un moteur de layout n'aurait rien à décider ici, et
 * coûterait une dépendance plus le risque de dessiner les liens avant que les
 * nœuds n'aient leurs dimensions.
 *
 * LE TRAIT PORTE LA CERTITUDE, et c'est le point à ne pas rater : une
 * renumérotation est CONSTATÉE (deux identifiants, une seule géométrie, dans le
 * même relevé) et se dessine en trait plein. Une division ou une réunion est
 * DÉDUITE d'un recouvrement de surfaces, et se dessine en pointillé. Le lecteur
 * doit pouvoir distinguer les deux d'un coup d'œil.
 */
interface Noeud {
  id: string
  commune: string
  prefixe: string
  section: string
  numero: string
  contenance: number | null
  presente: boolean
  vu_premier: string
  vu_dernier: string
}

interface Lien {
  id_avant: string
  id_apres: string
  type: string
  part_avant: number | null
  part_apres: number | null
  certain: boolean
  millesime: string
  saut: number
}

const props = defineProps<{
  focus: string
  noeuds: Noeud[]
  liens: Lien[]
  /** Code INSEE → nom, pour nommer les nœuds qui sortent de la commune. */
  communes?: Record<string, string>
}>()

/** La commune de la parcelle consultée : sert de référence à tout le graphe. */
const communeFocus = computed(
  () => props.noeuds.find((n) => n.id === props.focus)?.commune ?? '',
)

const LARGEUR_BOITE = 168
const HAUTEUR_BOITE = 58
const ECART_COLONNE = 240
const ECART_LIGNE = 76
const MARGE = 16

const parId = computed(() => new Map(props.noeuds.map((n) => [n.id, n])))

/**
 * Colonne de chaque nœud = sa GÉNÉRATION, et non sa distance à la parcelle
 * consultée. La nuance décide de la lisibilité du graphe.
 *
 * Le voisinage est parcouru dans les deux sens (voir l'API), donc un nœud peut
 * être atteint en descendant puis en remontant : la co-parente d'un successeur
 * est à deux sauts, mais elle appartient à la MÊME génération que la parcelle
 * consultée — elles ont nourri le même terrain. La ranger en colonne +2 la
 * ferait passer pour une descendante, ce qu'elle n'est pas.
 *
 * On propage donc le sens du lien : traverser avant → après avance d'une
 * génération, après → avant recule d'une. Un parcours en largeur assure que
 * chaque nœud reçoit la génération du plus court chemin, et le tri des liens
 * étant stable côté serveur, deux consultations donnent le même dessin.
 */
const colonnes = computed(() => {
  const voisins = new Map<string, { autre: string; delta: number }[]>()
  const ajouter = (de: string, autre: string, delta: number) => {
    if (!voisins.has(de)) voisins.set(de, [])
    voisins.get(de)!.push({ autre, delta })
  }
  for (const l of props.liens) {
    ajouter(l.id_avant, l.id_apres, 1)
    ajouter(l.id_apres, l.id_avant, -1)
  }

  const col = new Map<string, number>([[props.focus, 0]])
  const file = [props.focus]
  while (file.length) {
    const id = file.shift()!
    for (const { autre, delta } of voisins.get(id) ?? []) {
      if (col.has(autre)) continue
      col.set(autre, col.get(id)! + delta)
      file.push(autre)
    }
  }
  return col
})

interface Place extends Noeud {
  x: number
  y: number
  colonne: number
}

const places = computed<Place[]>(() => {
  const col = colonnes.value
  const groupes = new Map<number, string[]>()
  for (const [id, c] of col) {
    if (!groupes.has(c)) groupes.set(c, [])
    groupes.get(c)!.push(id)
  }
  // Tri stable par section puis numéro : deux consultations de la même parcelle
  // doivent produire exactement le même dessin.
  for (const ids of groupes.values()) {
    ids.sort((a, b) => a.localeCompare(b))
  }

  const cols = [...groupes.keys()].sort((a, b) => a - b)
  const hauteurMax = Math.max(...[...groupes.values()].map((g) => g.length))
  const out: Place[] = []

  cols.forEach((c, iCol) => {
    const ids = groupes.get(c)!
    // Colonne centrée verticalement : sans ça, une colonne d'un seul nœud
    // s'accrocherait en haut et les liens plongeraient en diagonale.
    const decalage = ((hauteurMax - ids.length) * ECART_LIGNE) / 2
    ids.forEach((id, iLigne) => {
      const n = parId.value.get(id)
      if (!n) return
      out.push({
        ...n,
        colonne: c,
        x: MARGE + iCol * ECART_COLONNE,
        y: MARGE + decalage + iLigne * ECART_LIGNE,
      })
    })
  })
  return out
})

const position = computed(() => new Map(places.value.map((p) => [p.id, p])))

const dimensions = computed(() => {
  const p = places.value
  if (!p.length) return { w: 0, h: 0 }
  return {
    w: Math.max(...p.map((n) => n.x)) + LARGEUR_BOITE + MARGE,
    h: Math.max(...p.map((n) => n.y)) + HAUTEUR_BOITE + MARGE,
  }
})

interface Trait {
  d: string
  lien: Lien
  epaisseur: number
  milieu: { x: number; y: number }
}

const traits = computed<Trait[]>(() => {
  const out: Trait[] = []
  for (const l of props.liens) {
    const a = position.value.get(l.id_avant)
    const b = position.value.get(l.id_apres)
    if (!a || !b) continue

    const x1 = a.x + LARGEUR_BOITE
    const y1 = a.y + HAUTEUR_BOITE / 2
    const x2 = b.x
    const y2 = b.y + HAUTEUR_BOITE / 2
    const dx = Math.max(30, (x2 - x1) / 2)

    // L'épaisseur encode la part de l'ancienne parcelle passée dans la nouvelle :
    // un trait fin signale un fragment, un trait épais la continuité du terrain.
    const part = l.part_avant ?? 0
    out.push({
      d: `M ${x1} ${y1} C ${x1 + dx} ${y1}, ${x2 - dx} ${y2}, ${x2} ${y2}`,
      lien: l,
      epaisseur: 1 + Math.min(1, part) * 4,
      milieu: { x: (x1 + x2) / 2, y: (y1 + y2) / 2 },
    })
  }
  return out
})

const COULEUR: Record<string, string> = {
  renumerotation: '#1d6b6f', // cadastre — le lien constaté
  division: '#b8933a', // insee — déduit
  reunion: '#b8933a',
  redecoupage: '#ac4227', // écart — le cas qu'on ne sait pas nommer
}

const survol = ref<Lien | null>(null)
const pct = (v: number | null) => (v == null ? '—' : `${Math.round(v * 100)} %`)

/**
 * Contenance affichée dans la carte du nœud.
 *
 * C'est la valeur DÉCLARÉE par le cadastre, pas la surface mesurée sur le tracé :
 * les deux concordent à moins de 2% mais ce sont deux choses différentes, et
 * c'est la contenance qui fait foi administrativement. On bascule en hectares
 * au-delà de 10 000 m², seuil où les mètres carrés cessent d'être lisibles.
 */
const contenance = (m2: number | null) =>
  m2 == null ? '—' : m2 >= 10000 ? `${(m2 / 10000).toFixed(2)} ha` : `${m2.toLocaleString('fr-FR')} m²`
</script>

<template>
  <div v-if="!liens.length" class="rounded-lg border border-default bg-elevated p-6 text-sm text-muted">
    Aucune filiation connue pour cette parcelle. Elle n’a ni disparu au profit
    d’autres, ni succédé à une parcelle antérieure, sur la période observée.
  </div>

  <div v-else class="overflow-x-auto rounded-lg border border-default bg-elevated p-4">
    <svg
      :viewBox="`0 0 ${dimensions.w} ${dimensions.h}`"
      :width="dimensions.w"
      :height="dimensions.h"
      class="max-w-none"
      role="img"
      aria-label="Graphe de filiation de la parcelle"
    >
      <!-- Les liens d'abord : ils passent sous les boîtes. -->
      <g fill="none">
        <path
          v-for="(t, i) in traits"
          :key="`t${i}`"
          :d="t.d"
          :stroke="COULEUR[t.lien.type] ?? '#6f7a80'"
          :stroke-width="t.epaisseur"
          :stroke-dasharray="t.lien.certain ? undefined : '5 4'"
          :opacity="survol && survol !== t.lien ? 0.2 : 0.75"
          @mouseenter="survol = t.lien"
          @mouseleave="survol = null"
        />
      </g>

      <!-- Part transmise, au milieu du trait. -->
      <g class="pointer-events-none">
        <text
          v-for="(t, i) in traits"
          :key="`l${i}`"
          :x="t.milieu.x"
          :y="t.milieu.y - 5"
          text-anchor="middle"
          font-size="10"
          font-family="ui-monospace, monospace"
          fill="currentColor"
          :opacity="survol && survol !== t.lien ? 0.15 : 0.55"
        >{{ pct(t.lien.part_avant) }}</text>
      </g>

      <g v-for="p in places" :key="p.id">
        <NuxtLink :to="`/parcelle/${p.id}`">
          <rect
            :x="p.x"
            :y="p.y"
            :width="LARGEUR_BOITE"
            :height="HAUTEUR_BOITE"
            rx="5"
            :fill="p.id === focus ? 'var(--color-cadastre-500)' : 'var(--ui-bg)'"
            :stroke="p.presente ? 'var(--ui-border)' : '#ac4227'"
            :stroke-width="p.id === focus ? 0 : 1.2"
            class="cursor-pointer"
          />
          <text
            :x="p.x + 10"
            :y="p.y + 18"
            font-size="13"
            font-weight="600"
            font-family="ui-monospace, monospace"
            :fill="p.id === focus ? '#fff' : 'currentColor'"
            class="pointer-events-none"
          >{{ p.section }} {{ p.numero }}</text>

          <!-- Contenance déclarée, alignée à droite sur la même ligne : elle
               donne l'échelle du terrain, ce qui rend les parts de filiation
               lisibles — « 24 % » ne dit rien tant qu'on ignore 24 % de quoi. -->
          <text
            :x="p.x + LARGEUR_BOITE - 10"
            :y="p.y + 18"
            text-anchor="end"
            font-size="10"
            font-family="ui-monospace, monospace"
            :fill="p.id === focus ? '#fff' : 'currentColor'"
            :opacity="p.id === focus ? 0.85 : 0.65"
            class="pointer-events-none"
          >{{ contenance(p.contenance) }}</text>

          <!-- L'identifiant complet, en clair. C'est LUI qui change lors d'une
               fusion de communes, alors que « section numéro » peut rester
               identique : sans lui, le graphe montrerait deux boîtes d'apparence
               identique sans qu'on voie ce qui les distingue. -->
          <text
            :x="p.x + 10"
            :y="p.y + 33"
            font-size="9.5"
            font-family="ui-monospace, monospace"
            :fill="p.id === focus ? '#fff' : 'currentColor'"
            :opacity="p.id === focus ? 0.75 : 0.5"
            class="pointer-events-none"
          >{{ p.id }}</text>

          <text
            :x="p.x + 10"
            :y="p.y + 48"
            font-size="10"
            font-family="ui-monospace, monospace"
            :fill="p.id === focus ? '#fff' : 'currentColor'"
            :opacity="p.id === focus ? 0.8 : 0.55"
            class="pointer-events-none"
          >{{ p.presente ? 'encore présente' : `jusqu’en ${p.vu_dernier.slice(0, 4)}` }}</text>

          <!-- Un nœud qui sort de la commune est l'information la plus forte que
               ce graphe puisse porter : le terrain a changé d'appartenance
               administrative. On le nomme explicitement plutôt que de laisser
               l'identifiant le trahir en silence. -->
          <text
            v-if="p.commune !== communeFocus"
            :x="p.x + LARGEUR_BOITE - 10"
            :y="p.y - 5"
            text-anchor="end"
            font-size="10"
            font-weight="600"
            fill="var(--color-ecart-500)"
            class="pointer-events-none"
          >{{ communes?.[p.commune] ?? p.commune }}</text>
        </NuxtLink>
      </g>
    </svg>
  </div>

  <div v-if="liens.length" class="mt-3 flex flex-wrap items-center gap-x-6 gap-y-2 text-xs text-muted">
    <span class="inline-flex items-center gap-2">
      <svg width="26" height="8"><line x1="0" y1="4" x2="26" y2="4" stroke="#1d6b6f" stroke-width="3" /></svg>
      renumérotation — <strong class="font-medium">constatée</strong>
    </span>
    <span class="inline-flex items-center gap-2">
      <svg width="26" height="8"><line x1="0" y1="4" x2="26" y2="4" stroke="#b8933a" stroke-width="3" stroke-dasharray="5 4" /></svg>
      division ou réunion — déduite du recouvrement
    </span>
    <span class="inline-flex items-center gap-2">
      <svg width="26" height="8"><line x1="0" y1="4" x2="26" y2="4" stroke="#ac4227" stroke-width="3" stroke-dasharray="5 4" /></svg>
      redécoupage — plusieurs parcelles échangent du terrain
    </span>
    <span>L’épaisseur du trait et le pourcentage donnent la part de terrain transmise.</span>
  </div>
</template>
