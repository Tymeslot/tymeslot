# Vendored Heroicons

Optimised SVGs from [Heroicons](https://github.com/tailwindlabs/heroicons),
vendored into the repository (MIT — see `LICENSE`).

Current version: **v2.2.0**

These files are the compile-time source for
`TymeslotWeb.Components.CoreComponents.Heroicons`, which reads them and emits
inline `<svg>` markup. They are committed deliberately rather than pulled from
`deps/`: a git-dep checkout is only reliably present in the *main* checkout, so
fresh worktrees and dep-less build contexts used to compile an empty icon map
and silently render blank tiles. Vendoring removes that failure mode entirely.

Directory layout mirrors the upstream `optimized/` tree:

```
24/outline   →  hero-<name>          (24px, stroked)
24/solid     →  hero-<name>-solid    (24px, filled)
20/solid     →  hero-<name>-mini     (20px, filled)
16/solid     →  hero-<name>-micro    (16px, filled)
```

## Updating

Do not hand-edit these files. To bump to a new Heroicons release:

```bash
mix tymeslot.refresh_heroicons v2.2.0
```

This fetches the given tag, replaces the SVGs here, and updates the version
above. Commit the resulting diff so the upgrade is reviewable.
