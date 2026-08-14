# Nexus Analytics — ce que j'ai compris du projet

> Rédigé après lecture intégrale des 5 branches GitLab (20 fichiers, ~150 Ko de Python)
> et vérification en direct des sources de données, le 14 août 2026.

---

## 1. L'objectif réel

Reconstituer **l'historique complet et vérifiable du cadastre français**, en partant des
communes puis en descendant vers les parcelles, pour aboutir à une **visualisation web
par commune** montrant « la vie » d'un territoire dans le temps — y compris quand il
change de code INSEE, fusionne, ou disparaît administrativement.

La phrase-clé : *« on aura un visuel par commune pour visualiser la vie d'une commune,
même après une fusion etc. ça change de code INSEE et tout »*.

Ça implique trois choses que le code actuel ne sait pas encore faire :

1. **Une identité territoriale qui survit au code INSEE.** Le code INSEE est un
   identifiant *administratif volatile*, pas un identifiant d'entité. Une commune peut
   changer de code sans changer de territoire (transfert de département, MOD 41),
   et garder son code en changeant complètement de territoire (absorption, MOD 32).
   Il faut donc un identifiant interne stable, et le code INSEE devient un attribut daté.

2. **Deux axes temporels distincts.** La date à laquelle une commune existe *légalement*
   (source INSEE/COG) et la date à laquelle on l'*observe* dans un millésime cadastral
   ne coïncident jamais. C'est la source principale de faux positifs.

3. **La distinction entre changement réel et bruit.** Une géométrie qui bouge entre deux
   millésimes est le plus souvent une simple amélioration du levé, pas un changement de
   périmètre. Sans ce filtre, tout le reste est noyé.

---

## 2. Ce que fait le code existant, branche par branche

| Branche | Contenu | État |
|---|---|---|
| `main` / `dev` | README GitLab par défaut | vide |
| `dev-feat-historique_dvf` | `valeurs_foncieres.py` — scraping DVF + envoi mail | prototype isolé |
| `dev-feat-historique_cadastre` | téléchargement + push cadastre, 1re version | abandonné |
| `dev-feat-historique_commune_unique_v2` | **la branche vivante** — 20 fichiers | le plus abouti |

### Le pipeline tel qu'il existe

```
download_cadastre_history_by_dep.py     scrape le HTML des index Apache, télécharge les .json.gz
        ↓                                suit les changements dans des JSON locaux
push_cadastre_history_by_dep_ogr2ogr.py décompresse, détecte les types, ogr2ogr → un schéma
        ↓                                PostgreSQL par millésime (cadastre_YYYY_MM_DD)
create_commune_unique_by_dep.py         parcourt les millésimes dans l'ordre, compare chaque
                                        commune au millésime précédent, écrit reference.communes_unique
                                        + historique.communes_changes
```

En parallèle, trois pistes explorées :
- `create_commune_unique_from_insee.py` — charger le COG INSEE (communes, mouvements, depuis 1943)
- `download_and_push_contours_administratifs_historique.py` — les contours Etalab 5 m
- `requete_pour_recuperer_les_communes_problématiques.txt` — croisement géométrique
  contours 5 m × communes reconstruites pour isoler les incohérences

### Les cas déjà identifiés dans le code

Le gros fichier `create_commune_unique_by_dep.py` (41 Ko) contient déjà une vraie
réflexion sur les cas limites, avec des statuts explicites :

- `NEW`, `UPDATE_NAME`, `UPDATE_DATE`, `UPDATE_GEOM`, `NO_CHANGE_GEOM`
- `inactive`, `inactive_no_fusion`, `inactive_fusioned_in_{millesime}`
- `no_present_in_millesime_but_still_active_and_present_in_other_millesime`

Ce dernier statut montre que le problème du **millésime trou** (une commune disparaît
d'un millésime par erreur de données puis revient) avait été rencontré et traité. C'est
un vrai signal : le code sait des choses sur le terrain qu'aucune documentation ne dit.

---

## 3. Pourquoi repartir de zéro est justifié

Ce ne sont pas des reproches de style, ce sont des blocages structurels.

**Injection SQL généralisée.** Toutes les requêtes sont des f-strings. `nom_commune`
est échappé à la main par `.replace("'", "''")` à deux endroits sur cinq. Sur des données
publiques ça ne casse pas la sécurité, mais ça casse l'exécution dès qu'un nom contient
une apostrophe non échappée — et il y en a (L'Abergement-Clémenciat, L'Île-Rousse).

**Aucune idempotence.** Un run interrompu laisse la base dans un état intermédiaire non
identifiable. Sur un traitement de plusieurs heures, c'est rédhibitoire. L'état est
dispersé dans des fichiers JSON locaux (`millesime_history.json`, `suivi_fichiers/`)
qui ne sont pas la source de vérité de ce qui est réellement en base.

**Le modèle ne peut pas représenter l'historique.** `reference.communes_unique` a
`code_commune` en clé primaire (v1) ou `(code_commune, millesime)` (v2). Aucune des deux
ne permet de dire « cette entité a porté le code X puis le code Y ». Le champ
`fusioned_to VARCHAR(5)` ne modélise qu'une fusion *simple et unique* : il ne sait pas
représenter une scission, ni une fusion partielle, ni le fait qu'une commune ait été
absorbée par deux communes différentes.

**La détection de fusion est fragile.** Le cœur de l'algorithme est :

```sql
SELECT code_commune FROM reference.communes_unique
WHERE ST_Contains(geom, (SELECT ST_Centroid(geom) FROM ... WHERE code_commune = 'X'))
```

Le centroïde d'un polygone concave ou d'un multipolygone (commune avec exclave) tombe
fréquemment **hors** de la commune. Et `fetchone()` prend arbitrairement le premier
résultat quand il y en a plusieurs. Il faut raisonner en **recouvrement surfacique
proportionnel**, pas en appartenance d'un point.

**Le scraping HTML est cassé.** La regex `\d{2}-[A-Za-z]{3}-\d{4} \d{2}:\d{2}` ne matche
plus : le serveur renvoie désormais des dates ISO (`2026-07-02T09:00:40.000Z`).

---

## 4. Ce que j'ai vérifié en direct cette nuit

### Le scraping HTML est inutile — il y a une API S3

Les fichiers sont servis par un bucket OVH qui **autorise le `ListObjectsV2` anonyme** :

```
https://cadastre.s3.rbx.io.cloud.ovh.net/?list-type=2&prefix=etalab-cadastre/
```

On récupère `Key`, `Size`, `ETag`, `LastModified` par objet. C'est la détection de
changement fiable que les JSON de suivi essayaient d'imiter. Plus de BeautifulSoup.

### La structure du dépôt a changé deux fois

| Période | Millésimes | Agrégat national disponible |
|---|---|---|
| 2017-07-06 → 2018-01-02 | 3 | aucun — `geojson/communes/{dep}/{insee}/`, ~35 000 fichiers |
| 2018-04-03 → 2022-04-01 | 16 | `shp/france/cadastre-france-communes-shp.zip` (388 Mo) |
| 2022-07-01 → 2026-06-01 | 16 | `geojson/france/cadastre-france-communes.json.gz` (223 Mo) |

**32 millésimes sur 35 se chargent avec un seul fichier.** Le code précédent itérait
par département (voire par commune) sur tous les millésimes — d'où sa lenteur.

### Volumétrie réelle mesurée

- Communes, un millésime : 223 Mo gz → 716 Mo de GeoJSON → **544 Mo en PostGIS**, 34 916 lignes
- Chargement mesuré : **30 secondes** par millésime (ogr2ogr + COPY)
- Communes, 35 millésimes : ~10 Go téléchargés, ~18 Go en base
- Parcelles, 35 millésimes : **195 Go** compressés — l'ordre de grandeur qui dimensionne le projet

Le GeoJSON national est écrit **une feature par ligne**, donc parsable en flux ligne
à ligne sans parseur JSON incrémental.

### Les écarts cadastre ↔ COG ne sont pas du bruit

Sur le millésime 2026-06-01, croisé avec le COG au 1ᵉʳ janvier 2026 :

| | |
|---|---|
| Communes au cadastre | 34 916 |
| Communes au COG (`TYPECOM='COM'`) | 34 875 |
| En commun | 34 869 |
| Au cadastre, absentes du COG | **47** |
| Au COG, absentes du cadastre | **6** |

Décomposition intégrale des 53 écarts — aucun n'est une erreur :

- **45 arrondissements municipaux.** Le cadastre découpe Paris, Lyon et Marseille par
  arrondissement (75101-75120, 69381-69389, 13201-13216) ; le COG les porte comme
  communes uniques (75056, 69123, 13055). Ce sont donc 45 codes en trop d'un côté et
  3 de l'autre. **Il faut une table de correspondance ARM ↔ commune**, pas un rejet.
- **Saint-Barthélemy (97123) et Saint-Martin (97127).** Sorties du COG en 2007 en
  devenant des collectivités d'outre-mer, mais toujours cadastrées. Le cadastre est un
  référentiel *foncier*, pas administratif — il n'a aucune raison de les retirer.
- **Île-de-Sein (29083), Île-Molène (29084), Suzan (09304).** Communes réelles **sans
  aucune couverture cadastrale vectorisée**. Elles existeront dans le COG à toutes les
  dates et n'apparaîtront jamais dans une géométrie. Toute règle du type « absente du
  cadastre ⇒ supprimée » produirait ici trois faux positifs permanents.

### Le référentiel des mouvements INSEE

13 734 mouvements depuis 1943, avec les codes officiels :

| MOD | Libellé officiel | Total | Depuis 2017 |
|---|---|---|---|
| 10 | Changement de nom | 1 407 | 99 |
| 20 | Création | 323 | 0 |
| 21 | Rétablissement | 699 | 26 |
| 30 | Suppression | 30 | 0 |
| 31 | Fusion simple | 1 316 | 0 |
| 32 | **Création de commune nouvelle** | **5 470** | **2 964** |
| 33 | Fusion association | 2 772 | 0 |
| 34 | Transformation de fusion association en fusion simple | 351 | 51 |
| 35 | Suppression de commune déléguée | 419 | 403 |
| 41 | Changement de code dû à un changement de département | 904 | 2 |
| 50 | Changement de code dû à un transfert de chef-lieu | 10 | 6 |
| 70 | Transformation de commune associée en commune déléguée | 18 | 1 |
| 71 | Rétablissement de commune déléguée | 14 | 14 |
| 72 | Création de commune déléguée | 1 | 1 |

Deux enseignements pour le modèle :

- **MOD 32 domine massivement** l'ère cadastrale (2 964 mouvements depuis 2017). La vague
  des communes nouvelles de 2016 (2 230 mouvements) et 2019 (1 244) est le phénomène
  central à modéliser.
- **MOD 21 et 71 (rétablissements) existent et sont récents.** Une commune peut
  *revenir à l'existence*. Un modèle qui traite la disparition comme un état terminal
  est faux.

---

## 5. Les objectifs concrets qui en découlent

1. **Un identifiant d'entité territoriale stable**, découplé du code INSEE, avec une
   table de liens datés vers les codes INSEE successifs.
2. **Un graphe de filiation typé** (fusion, scission, rétablissement, renommage,
   transfert), capable de porter des arêtes pondérées — une commune peut se répartir
   entre plusieurs successeurs.
3. **Un modèle bitemporel** séparant validité administrative (COG) et observation
   cadastrale (millésime).
4. **Un moteur de règles de validation** explicite, typé et rejouable, dont chaque
   anomalie est tracée — c'est la demande la plus insistante de l'utilisateur.
5. **Une réconciliation cadastre ↔ COG** qui gère nativement les 5 familles d'écarts
   ci-dessus au lieu de les traiter comme des erreurs.
6. **Un pipeline idempotent et reprenable**, à granularité millésime × couche, en
   TypeScript, dans un monorepo pnpm + turbo aligné sur les conventions de `todoride`.
7. **Une visualisation par commune** montrant la chronologie, les événements, et la
   confrontation entre les deux sources.

---

## 6. Déjà en place à cette heure

- PostgreSQL 17.10 + PostGIS 3.5.7 (**GEOS 3.14.1**, PROJ 9.8.1) en Docker sur le
  port 5434, conf versionnée dans `infra/docker/`.
  Le choix de l'image `alpine` est délibéré : la variante Debian est figée sur
  GEOS 3.9, qui n'a pas `ST_CoverageInvalidEdges` — l'outil exact pour valider
  qu'un département forme une couverture communale sans trou ni recouvrement.
- Schéma `raw` : chargement des millésimes en cours (32 millésimes).
- Schéma `insee` : COG 2026 complet (communes, mouvements, communes depuis 1943).
- Inventaire S3 exhaustif des 35 millésimes avec tailles et ETags.

---

## 7. BD TOPO Historique : testée, et écartée pour l'instant

*Ajouté le 14 août 2026, après téléchargement et analyse réels.*

J'avais d'abord affirmé que la BD TOPO ne remontait pas avant 2017. C'était faux :
le jeu **`BDTOPOHisto`** existe et remonte à **1993**.

```
https://data.geopf.fr/telechargement/resource/BDTOPOHisto
```

264 livraisons. Mais l'inventaire complet montre que ce n'est **pas** une série de
photographies annuelles du pays :

| Période | France entière | Par département |
|---|---|---|
| 1993 → 2002 | 1 à 2 livraisons/an | — |
| 2003 → 2009 | — | 30, 15, 68, 55, 50, 23, 2 selon l'année |

Aucune année ne couvre les 101 départements. C'est l'archive de **production** de
la BD TOPO au fil de sa constitution, pas un référentiel millésimé.

### Ce que contient réellement la livraison 2000 (téléchargée, 319 Mo, MD5 vérifié)

`DONNEES/ADMINISTRATIF/COMMUNE.shp`, 15 Mo pour la France — à comparer aux 544 Mo
du seul cadastre communal d'un millésime récent. Les attributs sont les bons
(`INSEE_COMM`, `NOM_COMM`, `POPULATION`, `INSEE_DEPT`), les noms sont accentués.

Trois obstacles, tous mesurés :

1. **Couverture fragmentaire, y compris à l'intérieur des départements.**
   2 006 entités seulement. L'Ain en compte 34 sur ~400 communes, la Marne 211
   sur ~620. L'emprise ne couvre qu'un quadrant du pays.

2. **Aucun polygone.** 1 703 `LINESTRING` et 303 `MULTILINESTRING`, zéro polygone.
   Et sur ces lignes, **844 seulement sont fermées** (42 %) : les 1 162 autres sont
   des fragments de limite. Là où la ligne est fermée, `ST_BuildArea` donne un
   polygone valide dans 200 cas sur 200 — la reconstruction marche, mais elle ne
   s'applique qu'à moins de la moitié des entités.

3. **`INSEE_COMM` est stocké en entier**, donc `01023` devient `1023`. Corrigeable
   par un remplissage à gauche, mais silencieux si on n'y pense pas.

### Vérification d'une livraison départementale

Le premier verdict reposait sur la seule année 2000, la plus défavorable. Contrôle
sur `BDTOPOHisto_3-0__SHP_LAMB93_D002_2008` (Aisne, 89 Mo) : l'archive **ne contient
aucune couche COMMUNE**. Un seul shapefile, thème végétation. Les livraisons
départementales postérieures à 2002 sont des lots de production **par thème**, pas
des jeux départementaux complets.

### Verdict

Inexploitable pour reconstituer un état national des communes avant 2018 —
confirmé sur deux types de livraison différents.

---

## 8. GEOFLA : la bonne source pour l'avant-2018

*Testé le 14 août 2026 sur données réelles.*

```
https://data.geopf.fr/telechargement/resource/GEOFLA
```

113 livraisons. Contrairement à la BD TOPO Historique, **une livraison France
entière par an de 1997 à 2016** (2014 manquant), plus les DROM en 1999.

### Livraison 2010 téléchargée (5,4 Mo) et chargée

| | |
|---|---|
| Géométrie | **Polygones** |
| Entités | **36 612** — couverture nationale complète |
| Emprise | tout l'Hexagone (99 km → 1 242 km en Lambert 93) |
| `INSEE_COM` | **String(5)** — les zéros de tête sont préservés |
| Autres champs | NOM_COMM, STATUT, SUPERFICIE, POPULATION, CODE_DEPT, NOM_DEPT, CODE_REG, NOM_REGION |

Un seul piège : l'encodage est en LATIN1 sans `.cpg`, `SHAPE_ENCODING=ISO-8859-1`
est obligatoire — exactement le même écueil que les shapefiles cadastre d'avant
2019-10.

### Ce que ça apporte réellement

Croisement de GEOFLA 2010 avec ce que le projet sait déjà :

| | |
|---|---|
| Communes dans GEOFLA 2010 | 36 612 |
| Déjà observées dans nos relevés cadastraux | 35 292 |
| **Jamais observées** (disparues avant 2018) | **1 320** |
| — dont déjà retrouvées via le préfixe cadastral | **1 315** |
| — **réellement nouvelles** | **5** |

La méthode du préfixe couvre donc 99,6 % de ce que GEOFLA 2010 apporterait. Mais
les 5 restantes sont précisément celles qu'elle ne peut **structurellement** pas
atteindre : Suzan `09304`, Île-de-Sein `29083`, Île-Molène `29084` — les communes
sans cadastre vectorisé — plus Gernicourt `02344` et Le Fresne-sur-Loire `44060`.

**Attention à ne pas généraliser** : ce ratio vaut pour 2010. Plus on remonte, plus
GEOFLA apporte de communes disparues avant que le préfixe n'ait pu en garder trace.
Chiffrer l'apport réel demande de charger les millésimes 1997→2016.

### La réserve de fond, inchangée

GEOFLA dérive de la BD CARTO : 10 Mo de polygones pour la France, contre 544 Mo pour
le seul cadastre communal d'un relevé récent. Comparer des surfaces entre les deux
mesurerait la méthode, pas le territoire. GEOFLA sert à **situer** une commune
disparue, pas à mesurer son évolution.
