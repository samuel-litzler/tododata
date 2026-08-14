// https://nuxt.com/docs/api/configuration/nuxt-config
export default defineNuxtConfig({
  ssr: true,

  future: { compatibilityVersion: 4 },

  modules: ['@nuxt/ui'],

  // La CSS de MapLibre doit être chargée statiquement : en import dynamique elle
  // n'est pas garantie d'être appliquée avant le premier rendu, et sans elle le
  // conteneur du canvas n'a aucune dimension — la carte reste invisible.
  css: ['~/assets/css/main.css', 'maplibre-gl/dist/maplibre-gl.css'],

  // Les deux thèmes sont conçus, comme dans les rapports : ocre pour le registre
  // INSEE, turquoise d'instrument pour la mesure cadastrale, vermillon réservé
  // aux divergences. On suit donc la préférence système plutôt que de forcer.
  colorMode: {
    preference: 'system',
    fallback: 'light',
    storageKey: 'nexus-color-mode',
    classSuffix: '',
  },

  devtools: { enabled: process.env.NODE_ENV !== 'production' },

  app: {
    head: {
      title: 'Nexus Analytics',
      titleTemplate: '%s — Nexus Analytics',
      htmlAttrs: { lang: 'fr' },
      meta: [
        { charset: 'utf-8' },
        { name: 'viewport', content: 'width=device-width, initial-scale=1' },
        {
          name: 'description',
          content:
            "Historique du cadastre français : la vie des communes millésime par millésime, confrontée au Code officiel géographique.",
        },
        { name: 'robots', content: 'noindex,nofollow' },
      ],
    },
  },

  // Les identifiants Postgres ne sortent jamais côté client : runtimeConfig sans
  // clé `public` reste serveur-only.
  runtimeConfig: {
    dbHost: process.env.DB_HOST ?? 'localhost',
    dbPort: process.env.DB_PORT ?? '5434',
    dbUser: process.env.DB_USER ?? 'nexus',
    dbPassword: process.env.DB_PASSWORD ?? 'nexus_dev',
    dbName: process.env.DB_NAME ?? 'nexus',
  },

  vite: {
    optimizeDeps: {
      // MapLibre télécharge et décode les tuiles dans un Web Worker. Le
      // pré-bundling de Vite casse ce worker (« maplibre-gl-worker.mjs does not
      // exist ») : la carte s'initialise, les contrôles s'affichent, mais AUCUNE
      // requête de tuile n'est jamais émise et le fond reste vide.
      // Symptôme trompeur : ni erreur JS, ni erreur réseau.
      exclude: ['maplibre-gl'],
    },
  },

  nitro: {
    // Les géométries simplifiées se compressent très bien et les réponses sont
    // purement dérivées : la compression vaut largement son coût CPU ici.
    compressPublicAssets: true,
  },
})
