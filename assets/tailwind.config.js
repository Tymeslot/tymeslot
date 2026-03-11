// See the Tailwind configuration guide for advanced usage
// https://tailwindcss.com/docs/configuration

const plugin = require("tailwindcss/plugin")
const fs = require("fs")
const path = require("path")

module.exports = {
  content: [
    "./js/**/*.js",
    "../lib/tymeslot_web.ex",
    "../lib/tymeslot_web/**/*.*ex",
    "../lib/tymeslot_web/controllers/auth/**/*.ex",
    "../lib/tymeslot_web/components/auth/**/*.ex"
  ],
  safelist: [
    // Design token typography classes — used by SaaS pages via app.css
    "display-xl",
    "display-lg",
    "display-md",
    // Ensure all meeting type icons are included in the CSS build
    "hero-bolt",
    "hero-chat-bubble-left-right",
    "hero-hand-raised",
    "hero-chart-bar",
    "hero-flag",
    "hero-clock",
    "hero-phone",
    "hero-light-bulb",
    "hero-wrench-screwdriver",
    "hero-book-open",
    "hero-rocket-launch",
    "hero-beaker",
    "hero-clipboard-document-check",
    "hero-presentation-chart-line",
    // Additional icons used in the UI
    "hero-user",
    "hero-video-camera",
    "hero-link",
    // Utility classes for consistent sizing
    "w-10",
    "h-10",
    "h-16",
    "h-20",
    "w-8",
    "h-8",
    "w-6",
    "h-6",
    "box-border"
  ],
  theme: {
    extend: {
      colors: {
        brand: "#FD4F00",
        // Map turquoise and cyan to CSS variables for design token consistency
        // We use hex values directly here to ensure opacity modifiers work (/50, etc.)
        // while keeping them in sync with variables.css
        turquoise: {
          50: '#f0fdfa',
          100: '#ccfbf1',
          200: '#99f6e4',
          300: '#5eead4',
          400: '#2dd4bf',
          500: '#14b8a6',
          600: '#0d9488',
          700: '#0f766e',
          800: '#115e59',
          900: '#134e4a',
          950: '#042f2e',
        },
        cyan: {
          50: '#ecfeff',
          100: '#cffafe',
          200: '#a5f3fc',
          300: '#67e8f9',
          400: '#22d3ee',
          500: '#06b6d4',
          600: '#0891b2',
          700: '#0e7490',
          800: '#155e75',
          900: '#164e63',
          950: '#083344',
        },
        glass: {
          light: 'var(--color-glass-bg-light)',
          medium: 'var(--color-glass-bg-medium)',
          strong: 'var(--color-glass-bg-strong)',
          card: 'var(--color-glass-bg-card)',
          'card-enhanced': 'var(--color-glass-bg-card-enhanced)',
          overlay: 'var(--color-glass-bg-overlay)',
          'overlay-enhanced': 'var(--color-glass-bg-overlay-enhanced)',
        },
        tymeslot: {
          50: '#fafafa',
          100: '#f4f4f5',
          200: '#e4e4e7',
          300: '#d4d4d8',
          400: '#a1a1aa',
          500: '#71717a',
          600: '#52525b',
          700: '#3f3f46',
          800: '#27272a',
          900: '#18181b',
          950: '#09090b',
        }
      },
      // Add custom design token utilities without overriding defaults
      boxShadow: {
        'glass-sm': 'var(--shadow-glass-sm)',
        'glass-md': 'var(--shadow-glass-md)',
        'glass-lg': 'var(--shadow-glass-lg)',
        'glass-xl': 'var(--shadow-glass-xl)',
        'glass-card': 'var(--shadow-glass-card-enhanced)',
      },
      transitionProperty: {
        'glass': 'var(--transition-glass)',
      },
      backdropBlur: {
        'glass-light': 'var(--glass-blur-light)',
        'glass-medium': 'var(--glass-blur-medium)',
        'glass-strong': 'var(--glass-blur-strong)',
        'glass-heavy': 'var(--glass-blur-heavy)',
      },
      fontSize: {
        'token-xs': 'var(--font-size-xs)',
        'token-sm': 'var(--font-size-sm)',
        'token-base': 'var(--font-size-base)',
        'token-lg': 'var(--font-size-lg)',
        'token-xl': 'var(--font-size-xl)',
        'token-2xl': 'var(--font-size-2xl)',
        'token-3xl': 'var(--font-size-3xl)',
        'token-4xl': 'var(--font-size-4xl)',
        'token-5xl': 'var(--font-size-5xl)',
        'token-6xl': 'var(--font-size-6xl)',
        'token-7xl': 'var(--font-size-7xl)',
      },
      borderRadius: {
        'token-sm': 'var(--radius-sm)',
        'token-md': 'var(--radius-md)',
        'token-lg': 'var(--radius-lg)',
        'token-xl': 'var(--radius-xl)',
        'token-2xl': 'var(--radius-2xl)',
        'token-3xl': 'var(--radius-3xl)',
      }
    },
  },
  plugins: [
    require("@tailwindcss/forms"),
    // Allows prefixing tailwind classes with LiveView classes to add rules
    // only when LiveView classes are applied, for example:
    //
    //     <div class="phx-click-loading:animate-ping">
    //
    plugin(({addVariant}) => addVariant("phx-click-loading", [".phx-click-loading&", ".phx-click-loading &"])),
    plugin(({addVariant}) => addVariant("phx-submit-loading", [".phx-submit-loading&", ".phx-submit-loading &"])),
    plugin(({addVariant}) => addVariant("phx-change-loading", [".phx-change-loading&", ".phx-change-loading &"])),

    // Embeds Heroicons (https://heroicons.com) into your app.css bundle
    // See your `CoreComponents.icon/1` for more information.
    //
    plugin(function({matchComponents, theme}) {
      let iconsDir = path.join(__dirname, "../deps/heroicons/optimized")
      let values = {}
      let icons = [
        ["", "/24/outline"],
        ["-solid", "/24/solid"],
        ["-mini", "/20/solid"],
        ["-micro", "/16/solid"]
      ]

      // On localhost, we can speed up the build by scanning for used icons instead of loading all of them
      // This avoids readdirSync/readFileSync for ~6000 files
      let usedIcons = null
      if (process.env.NODE_ENV !== "production") {
        try {
          const { execSync } = require("child_process")
          // Search for hero- prefixes in lib and js directories
          // We use a simple regex to find potential icon names
          const searchPath = path.join(__dirname, "../lib")
          const jsPath = path.join(__dirname, "./js")
          const output = execSync(`grep -rEho "hero-[a-z0-9-]+" "${searchPath}" "${jsPath}" | sort | uniq`).toString()
          usedIcons = new Set(output.split("\n").map(line => line.replace(/^hero-/, "").replace(/-(solid|mini|micro)$/, "")))
        } catch (e) {
          // Fallback to full library if grep fails
          usedIcons = null
        }
      }

      icons.forEach(([suffix, dir]) => {
        if (usedIcons) {
          usedIcons.forEach(iconName => {
            if (!iconName) return
            const file = `${iconName}.svg`
            const fullPath = path.join(iconsDir, dir, file)
            if (fs.existsSync(fullPath)) {
              let name = iconName + suffix
              values[name] = {name, fullPath}
            }
          })
        } else {
          fs.readdirSync(path.join(iconsDir, dir)).forEach(file => {
            let name = path.basename(file, ".svg") + suffix
            values[name] = {name, fullPath: path.join(iconsDir, dir, file)}
          })
        }
      })

      matchComponents({
        "hero": ({name, fullPath}) => {
          let content = fs.readFileSync(fullPath).toString().replace(/\r?\n|\r/g, "")
          let size = theme("spacing.6")
          if (name.endsWith("-mini")) {
            size = theme("spacing.5")
          } else if (name.endsWith("-micro")) {
            size = theme("spacing.4")
          }
          return {
            [`--hero-${name}`]: `url('data:image/svg+xml;utf8,${content}')`,
            "-webkit-mask": `var(--hero-${name})`,
            "mask": `var(--hero-${name})`,
            "mask-repeat": "no-repeat",
            "background-color": "currentColor",
            "vertical-align": "middle",
            "display": "inline-block",
            "width": size,
            "height": size
          }
        }
      }, {values})
    })
  ]
}
