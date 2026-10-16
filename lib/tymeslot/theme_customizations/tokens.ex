defmodule Tymeslot.ThemeCustomizations.Tokens do
  @moduledoc """
  What a theme's customisation resolves to for one page view.

    * `vars` are CSS custom properties for the page's `:root`, keyed by full
      property name (`"--theme-primary"`), values without the trailing `;`.
    * `dark_vars` are the same for a visitor whose OS is in dark mode,
      written inside `@media (prefers-color-scheme: dark)`. A palette fills
      them only for a light scheme with a dark counterpart in a group with
      `follow_os: true`; otherwise they are empty and the page keeps `vars`.
    * `media` is what the option groups resolve for the theme to render, keyed
      by name, each value already safe to emit: `:background` is the page
      background descriptor (`Options.Background.descriptor/1`), and a group
      of a theme's own adds its key the same way. A key is absent when nothing
      resolved (`Specs.media/2`).
  """

  @type css_vars :: %{optional(String.t()) => String.t()}
  @type media :: %{optional(atom()) => term()}

  @type t :: %__MODULE__{vars: css_vars(), dark_vars: css_vars(), media: media()}

  defstruct vars: %{}, dark_vars: %{}, media: %{}
end
