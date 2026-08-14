const { VectorTile } = require('@mapbox/vector-tile')
const pbfMod = require('pbf')
const Pbf = pbfMod.PbfReader
;(async () => {
  const url = process.argv[2] ?? 'http://localhost:3400/api/tiles/4/8/5'
  const buf = Buffer.from(await (await fetch(url)).arrayBuffer())
  console.log('octets reçus :', buf.length)
  try {
    const t = new VectorTile(new Pbf(buf))
    const noms = Object.keys(t.layers)
    console.log('couches :', noms.length ? noms.join(', ') : '(AUCUNE)')
    for (const n of noms) {
      const l = t.layers[n]
      console.log(`  ${n}: ${l.length} entités, extent=${l.extent}`)
      if (l.length) {
        const f = l.feature(0)
        const g = f.loadGeometry()
        console.log('    type:', f.type, '| anneaux:', g.length, '| pts:', g[0]?.length)
        console.log('    props:', JSON.stringify(f.properties).slice(0, 130))
      }
    }
  } catch (e) { console.log('ÉCHEC DE PARSING :', e.message) }
})()
