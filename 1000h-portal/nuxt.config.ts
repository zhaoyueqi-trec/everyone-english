// https://nuxt.com/docs/api/configuration/nuxt-config
export default defineNuxtConfig({
  devtools: { enabled: true },
  css: ["~/styles/main.css"],
  site: {
    url: "https://5ways.duckdns.org/every1english/",
    name: "Enjoy App",
    description: "Welcome to Enjoy App!",
    tagline: "",
    defaultLocale: "zh", // not needed if you have @nuxtjs/i18n installed
  },

  app: {
    // 部署在 https://5ways.duckdns.org/every1english/ 这个子路径下,
    // 没有这个配置的话页面内部资源/路由都会按域名根路径算,直接 404。
    baseURL: "/every1english/",
    buildAssetsDir: "portal-assets",
    head: {
      viewport:
        "width=device-width, initial-scale=1, maximum-scale=1.0, user-scalable=no, viewport-fit=cover",
      meta: [{ name: "theme-color", content: "#ffffff" }],
      link: [
        {
          rel: "apple-touch-icon",
          sizes: "180x180",
          href: "/portal-static/images/apple-touch-icon.png",
        },
        {
          rel: "icon",
          type: "image/x-icon",
          sizes: "48x48",
          href: "/portal-static/images/favicon.ico",
        },
        {
          rel: "icon",
          type: "image/png",
          sizes: "32x32",
          href: "/portal-static/images/favicon-32x32.png",
        },
        {
          rel: "icon",
          type: "image/png",
          sizes: "16x16",
          href: "/portal-static/images/favicon-16x16.png",
        },
      ],
      script: [],
    },
  },

  postcss: {
    plugins: {
      tailwindcss: {},
      autoprefixer: {},
    },
  },

  modules: ["@nuxtjs/seo"],
});
