// Heroicons Tailwind plugin, extracted to a standalone @plugin module for
// Tailwind v4. The v4 standalone CLI cannot load a full legacy JS config via
// @config (it fails transpiling it), but it *can* load individual JS plugins
// referenced with `@plugin`. Keeping this file at the assets/ root means
// __dirname stays the same as when it lived inline in tailwind.config.js, so
// every relative path (../deps, ../lib, ./js) is unchanged.
//
// Embeds Heroicons (https://heroicons.com) into the CSS bundle as mask images.
// See `CoreComponents.icon/1` for usage.

const plugin = require("tailwindcss/plugin")
const fs = require("fs")
const path = require("path")

module.exports = plugin(function ({matchComponents, theme}) {
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
      const {execSync} = require("child_process")
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

  matchComponents(
    {
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
    },
    {values}
  )
})
