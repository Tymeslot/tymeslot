defmodule Tymeslot.Emails.Shared.Styles.DarkMode do
  @moduledoc """
  Builds the dark-mode stylesheet for an email from a light-to-dark colour map.

  MJML inlines every colour as an attribute or inline style, so a dark
  stylesheet cannot restyle elements through classes alone. Instead this
  module matches the inlined light values themselves with attribute
  selectors (`[style*="background-color:#fafaf6"]`, `[bgcolor="#fafaf6"]`)
  and swaps in the dark value with `!important`, which beats an inline
  declaration. Every template therefore gets dark mode from the palette map
  alone, without a class on each element, and a new component picks it up
  as long as it draws its colours from the tokens.

  The rules sit inside `@media (prefers-color-scheme: dark)`, honoured by
  Apple Mail (macOS and iOS), Outlook for Mac and most WebKit-based clients.
  Clients that ignore it keep the light design, or apply their own forced
  inversion (Gmail apps, Outlook.com), which the light palette is already
  chosen to survive. The output is a standalone `<style>` element: Gmail
  drops a whole style block containing a selector it does not support, so
  keeping these rules apart protects the mobile rules in the main block.

  A map has these keys, each optional:

  - `:text` — `{light, dark}` pairs for text colours (`color:`)
  - `:background` — `{light, dark}` pairs for backgrounds (`background`,
    `background-color`, `bgcolor`)
  - `:border` — `{light, dark}` pairs for border colours
  - `:keep_text` — `{background, text}` pairs: an element painted with
    `background` keeps its `text` colour even though `:text` maps it. Buttons
    pick dark ink on a light accent, and that ink must stay dark.
  - `:rules` — extra CSS for class-based styles, placed inside the media query
  """

  @type pair :: {String.t(), String.t()}

  @type colour_map :: %{
          optional(:text) => [pair()],
          optional(:background) => [pair()],
          optional(:border) => [pair()],
          optional(:keep_text) => [pair()],
          optional(:rules) => String.t()
        }

  @doc "Renders the `<style>` element for `colour_map`."
  @spec stylesheet(colour_map()) :: String.t()
  def stylesheet(colour_map) do
    rules =
      [
        rules_for(Map.get(colour_map, :text, []), &text_selectors/1, "color"),
        rules_for(Map.get(colour_map, :background, []), &background_selectors/1, "background-color"),
        rules_for(Map.get(colour_map, :border, []), &border_selectors/1, "border-color"),
        keep_text_rules(Map.get(colour_map, :keep_text, [])),
        Map.get(colour_map, :rules, "")
      ]
      |> List.flatten()
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    """
    <style type="text/css">
    :root { color-scheme: light dark; supported-color-schemes: light dark; }
    @media (prefers-color-scheme: dark) {
    #{rules}
    }
    </style>
    """
  end

  defp rules_for(pairs, selectors_fun, property) do
    pairs
    |> Enum.uniq_by(fn {light, _dark} -> light end)
    |> Enum.map(fn {light, dark} ->
      "#{Enum.join(selectors_fun.(light), ",")}{#{property}:#{dark} !important;}"
    end)
  end

  # `color:` must match only the text property, never the tail of
  # `background-color:`, so it is anchored to the start of the attribute or to
  # a preceding semicolon. MJML writes `color:#x`; hand-written spans write
  # `color: #x`, after `;` or `; `.
  defp text_selectors(hex) do
    for value <- ["color:#{hex}", "color: #{hex}"],
        selector <- [
          ~s([style^="#{value}"]),
          ~s([style*=";#{value}"]),
          ~s([style*="; #{value}"])
        ],
        do: selector
  end

  defp background_selectors(hex) do
    [~s([bgcolor="#{hex}"])] ++
      for property <- ["background", "background-color"],
          separator <- [":", ": "],
          do: ~s([style*="#{property}#{separator}#{hex}"])
  end

  # Borders are written `1px solid #x` (components) or `solid 1px #x` (MJML).
  defp border_selectors(hex) do
    [~s([style*="solid #{hex}"]), ~s([style*="px #{hex}"])]
  end

  # Two attribute selectors outrank the single one in the `:text` rules.
  defp keep_text_rules(pairs) do
    Enum.map(pairs, fn {background, text} ->
      selectors =
        for value <- ["color:#{text}", "color: #{text}"],
            do: ~s([style*="#{background}"][style*="#{value}"])

      "#{Enum.join(selectors, ",")}{color:#{text} !important;}"
    end)
  end
end
