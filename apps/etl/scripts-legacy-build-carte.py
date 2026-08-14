#!/usr/bin/env python3
"""Assemble la carte des fusions : encode les géométries et injecte dans le template.

Les coordonnées sont quantifiées à 1e-5 degré (~1 m, bien en dessous de la
tolérance de simplification de 30 m appliquée en SQL) puis delta-encodées.
Un couple de coordonnées passe ainsi de ~17 caractères de JSON flottant
("[5.33100,45.94343]") à ~6 ("12,-45"), soit un facteur ~3 sur le total.
"""
import json
import pathlib
import sys

Q = 100000  # 1e-5 degré
ROOT = pathlib.Path(__file__).resolve().parent.parent
WORK = pathlib.Path('/home/bbw/data/nexus-cadastre/work')


def encode_rings(geom):
    """GeoJSON Polygon/MultiPolygon -> liste d'anneaux delta-encodés, + bbox."""
    if geom is None:
        return [], None
    polys = geom['coordinates'] if geom['type'] == 'MultiPolygon' else [geom['coordinates']]
    rings, bb = [], [1e9, 1e9, -1e9, -1e9]
    for poly in polys:
        for ring in poly:
            px = py = 0
            flat = []
            for x, y in ring:
                bb[0] = min(bb[0], x); bb[1] = min(bb[1], y)
                bb[2] = max(bb[2], x); bb[3] = max(bb[3], y)
                qx, qy = round(x * Q), round(y * Q)
                flat.append(qx - px); flat.append(qy - py)
                px, py = qx, qy
            if len(flat) >= 8:          # au moins 4 points : sinon l'anneau est dégénéré
                rings.append(flat)
    return rings, (bb if rings else None)


def main():
    src = WORK / 'carte-fusions.jsonl'
    communes = {}
    for line in src.open(encoding='utf-8'):
        line = line.strip()
        if not line:
            continue
        c = json.loads(line)
        parts, bb = [], [1e9, 1e9, -1e9, -1e9]
        for p in c['parts']:
            rings, pbb = encode_rings(p.get('geom'))
            if not rings:
                continue
            for i in range(2):
                bb[i] = min(bb[i], pbb[i])
            for i in range(2, 4):
                bb[i] = max(bb[i], pbb[i])
            parts.append({
                'p': p['prefixe'],
                't': p.get('nature'),
                'c': p.get('code'),
                'n': p.get('nom'),
                'a': p.get('ancienne'),
                'f': p.get('fusion'),
                'd': p.get('debut'),
                'e': p.get('fin'),
                'k': p.get('km2'),
                'g': rings,
            })
        if not parts:
            continue
        communes[c['commune']] = {
            'n': c.get('nom_cog') or c.get('nom'),
            'nc': c.get('nom'),
            'b': [round(v, 5) for v in bb],
            'p': parts,
        }

    payload = {'q': Q, 'communes': communes}
    blob = json.dumps(payload, separators=(',', ':'), ensure_ascii=False)
    print(f"communes      : {len(communes)}")
    print(f"territoires   : {sum(len(v['p']) for v in communes.values())}")
    print(f"charge encodée: {len(blob.encode())/1048576:.2f} Mo")

    tpl = (ROOT / 'docs' / 'carte-fusions.template.html').read_text(encoding='utf-8')
    out = tpl.replace('__DATA__', blob.replace('<', '\\u003c'))
    if '__DATA__' in out:
        sys.exit('placeholder __DATA__ non remplacé')
    dst = ROOT / 'docs' / 'carte-fusions.html'
    dst.write_text(out, encoding='utf-8')
    print(f"écrit         : {dst} ({dst.stat().st_size/1048576:.2f} Mo)")


if __name__ == '__main__':
    main()
