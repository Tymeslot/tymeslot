defmodule TymeslotWeb.Components.CoreComponents.Heroicons do
  @moduledoc """
  Compile-time inline-SVG source for Heroicons.

  Replaces the build-time `assets/heroicons.js` mask-image plugin. Instead of
  emitting `.hero-*` CSS utility classes (which only land in whichever compiled
  stylesheet's scanner happened to see the name — the cause of SaaS-only icons
  silently not painting, and of the `@source inline(...)` safelist), every icon
  is read from the `heroicons` dep at *compile time* and rendered as an inline
  `<svg>` by `CoreComponents.Icons.icon/1`.

  Because the markup ships in the HTML, rendering no longer depends on a
  per-bundle Tailwind scan: any name — including dynamically chosen ones — paints
  identically in Core and SaaS, with no safelist to maintain.

  The full set is available (names arrive dynamically from the database and from
  theme duration maps), but the map lives only in the BEAM — the browser receives
  just the icons actually rendered.
  """

  alias TymeslotWeb.Components.CoreComponents.IconSource

  # The SVGs are vendored into priv (see priv/heroicons/README.md) rather than
  # pulled from a git dep: a dep checkout was only reliably present in the main
  # checkout, so fresh worktrees compiled an empty map and silently rendered
  # blank tiles. priv is resolved relative to this module so the read is valid
  # whenever the source is compiled (this all happens at compile time — the map
  # is baked into the BEAM, the path is never consulted at runtime).
  @optimized_dir Path.expand("../../../../priv/heroicons", __DIR__)

  # {name suffix, sub-directory, intrinsic px}: the four styles, outline by
  # default and `-solid` / `-mini` / `-micro` for the others.
  @sources [
    {"", "24/outline", 24},
    {"-solid", "24/solid", 24},
    {"-mini", "20/solid", 20},
    {"-micro", "16/solid", 16}
  ]

  @icons (for {suffix, subdir, size} <- @sources, reduce: %{} do
            icons ->
              dir = Path.join(@optimized_dir, subdir)
              for file <- IconSource.files(dir), do: @external_resource(Path.join(dir, file))
              Map.merge(icons, IconSource.load(dir, prefix: "hero-", suffix: suffix, size: size))
          end)

  # Fail the build loudly rather than silently shipping blank icon tiles — the
  # exact failure mode that motivated vendoring the SVGs into priv.
  if @icons == %{} do
    raise "No heroicons compiled from #{@optimized_dir}. " <>
            "Expected vendored SVGs (run `mix tymeslot.refresh_heroicons`); see priv/heroicons/README.md."
  end

  @doc """
  Looks up a heroicon by its `hero-*` name.

  Returns `{:ok, icon}` (see `IconSource.icon/0`) or `:error`.
  """
  @spec fetch(String.t()) :: {:ok, IconSource.icon()} | :error
  def fetch(name), do: Map.fetch(@icons, name)

  @doc "Whether a `hero-*` name is known at compile time."
  @spec known?(String.t()) :: boolean()
  def known?(name), do: Map.has_key?(@icons, name)

  @doc "All known `hero-*` icon names."
  @spec names() :: [String.t()]
  def names, do: Map.keys(@icons)
end
