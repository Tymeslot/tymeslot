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

  # heroicons is declared `app: false, compile: false` in mix.exs, so it is just
  # SVG files under deps/heroicons/optimized — resolve relative to this module.
  @optimized_dir Path.expand("../../../../deps/heroicons/optimized", __DIR__)

  # {name suffix, sub-directory, outline?, intrinsic px} — mirrors the four
  # styles the old plugin produced (default / -solid / -mini / -micro).
  @sources [
    {"", "24/outline", true, 24},
    {"-solid", "24/solid", false, 24},
    {"-mini", "20/solid", false, 20},
    {"-micro", "16/solid", false, 16}
  ]

  @icons (for {suffix, subdir, outline?, size} <- @sources,
              dir = Path.join(@optimized_dir, subdir),
              File.dir?(dir),
              file <- File.ls!(dir),
              String.ends_with?(file, ".svg"),
              into: %{} do
            content = dir |> Path.join(file) |> File.read!()

            view_box =
              case Regex.run(~r/viewBox="([^"]*)"/, content) do
                [_, vb] -> vb
                _ -> "0 0 #{size} #{size}"
              end

            body =
              case Regex.run(~r/<svg[^>]*>(.*)<\/svg>/s, content) do
                [_, inner] -> String.trim(inner)
                _ -> ""
              end

            name = "hero-" <> Path.basename(file, ".svg") <> suffix
            {name, %{view_box: view_box, body: body, outline?: outline?, size: size}}
          end)

  @doc """
  Looks up a heroicon by its `hero-*` name.

  Returns `{:ok, %{view_box:, body:, outline?:, size:}}` or `:error`.
  """
  @spec fetch(String.t()) :: {:ok, map()} | :error
  def fetch(name), do: Map.fetch(@icons, name)

  @doc "Whether a `hero-*` name is known at compile time."
  @spec known?(String.t()) :: boolean()
  def known?(name), do: Map.has_key?(@icons, name)
end
