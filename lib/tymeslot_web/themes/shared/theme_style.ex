defmodule TymeslotWeb.Themes.Shared.ThemeStyle do
  @moduledoc """
  Renders a theme's `%Tokens{}` as CSS.

  `theme_style/1` writes one `<style>` element whose custom properties sit on
  `:root:root`. The doubled pseudo-class outranks each theme's own `:root`
  defaults by specificity, so the override holds wherever the element lands in
  the document. Inputs are only ever overridden on `:root` (see the theme
  skill): the derived tokens in `scheduling/shared/tokens.css` read them there.

  `dark_vars`, when there are any, follow in a
  `@media (prefers-color-scheme: dark)` block on the same selector; it comes
  after the root block, so it wins while the OS is dark. Only custom
  properties are written: a theme that follows the OS declares
  `color-scheme: light dark`, and any dark role that is not a palette input,
  in its own CSS.

  Every name and value passes a strict filter before it is written: a name
  must be a plain custom property, and a value may use only the characters a
  colour, gradient or `var()` reference needs, so nothing can end a
  declaration, a block or the element. `Validation.sanitize_css/1` then checks
  the assembled block as a second line of defence.

  `inline_background/1` turns a background descriptor into the inline style
  the wrappers put on their background element.
  """
  use Phoenix.Component

  require Logger

  alias Tymeslot.ThemeCustomizations.Options.Background
  alias Tymeslot.ThemeCustomizations.Tokens
  alias Tymeslot.ThemeCustomizations.Validation

  @name_pattern ~r/\A--[a-z0-9]+(?:-[a-z0-9]+)*\z/
  @value_pattern ~r/\A[a-zA-Z0-9#%(),.\-\/ ]+\z/

  attr :tokens, :any, default: nil, doc: "a `%Tokens{}`, or nil for no customisation"

  @doc "Renders the tokens' custom properties in one `<style>` element, or nothing."
  @spec theme_style(map()) :: Phoenix.LiveView.Rendered.t()
  def theme_style(assigns) do
    assigns = assign(assigns, :css, css(assigns.tokens))

    ~H"""
    <style :if={@css != ""} type="text/css" phx-no-format><%= Phoenix.HTML.raw(@css) %></style>
    """
  end

  @doc "The CSS for a set of tokens; empty when there is nothing safe to write."
  @spec css(Tokens.t() | nil) :: String.t()
  def css(%Tokens{vars: vars, dark_vars: dark_vars}) do
    [root_block(vars), dark_block(dark_vars)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> Validation.sanitize_css()
  end

  def css(nil), do: ""

  @doc "The inline style for a background descriptor; `nil` when it has none."
  @spec inline_background(Background.descriptor() | nil) :: String.t() | nil
  def inline_background(%{kind: :gradient, css: css}), do: "background: #{css};"
  def inline_background(%{kind: :color, color: hex}), do: "background-color: #{hex};"

  def inline_background(%{kind: :image, url: url}) do
    "background-image: url('#{url}'); background-size: cover; " <>
      "background-position: center; background-repeat: no-repeat;"
  end

  def inline_background(_video_or_nil), do: nil

  defp root_block(vars) do
    case declarations(vars) do
      "" -> ""
      body -> ":root:root { " <> body <> " }"
    end
  end

  defp dark_block(vars) do
    case root_block(vars) do
      "" -> ""
      block -> "@media (prefers-color-scheme: dark) { " <> block <> " }"
    end
  end

  defp declarations(vars) do
    vars
    |> Enum.sort()
    |> Enum.filter(fn {name, value} -> safe?(name, value) end)
    |> Enum.map_join(" ", fn {name, value} -> "#{name}: #{value};" end)
  end

  defp safe?(name, value) when is_binary(name) and is_binary(value) do
    if Regex.match?(@name_pattern, name) and Regex.match?(@value_pattern, value) do
      true
    else
      Logger.warning("theme token dropped by ThemeStyle filter", token_byte_size: byte_size(name))
      false
    end
  end

  defp safe?(_name, _value), do: false
end
