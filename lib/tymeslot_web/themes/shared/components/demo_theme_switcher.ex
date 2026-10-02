defmodule TymeslotWeb.Themes.Shared.Components.DemoThemeSwitcher do
  @moduledoc """
  Lets a visitor of a demo booking page see it in another theme: one link
  per theme the pickers offer (`ThemeInfo.theme_options/0`), each to the
  path of the route the page was mounted on
  (`PathHandlers.current_base_path/1`) with `?theme=<id>`, the theme
  showing marked current. The steps after the overview are state inside
  that one LiveView, so a switch from one of them reopens the route's own
  step. A switch keeps no other query parameter: the locale persists
  through the session, and UTM parameters are not carried.

  `Shared.SchedulingPage` renders it above the step of every theme, only
  when the page is a demo (`:demo_theme_switcher`, set at mount from
  `Tymeslot.Demo.demo_profile?/1`). With the default demo provider no page
  is a demo, so a self-hosted install never shows it.

  The links are full page loads, not LiveView navigation: a theme's
  stylesheet comes with the root layout, which live navigation keeps. The
  flow's own redirects then carry the chosen theme
  (`PathHandlers.demo_theme_param/1`).

  The same markup on every theme, styled once in
  `shared/components/preview-notice.css` from the role tokens every theme
  defines (`shared/tokens.css`). Paper's and Folio's column puts it above
  the step as it is; Quill and Rhythm place it in their own `base.css`.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Themes.Core.Registry
  alias TymeslotWeb.Themes.Core.ThemeInfo
  alias TymeslotWeb.Themes.Shared.PathHandlers

  attr :theme_id, :string, required: true, doc: "the theme the page shows"
  attr :base_path, :string, required: true, doc: "the mounted route's path, without a query"
  attr :options, :list, default: nil, doc: "`{name, id}` pairs; the active themes when nil"

  @doc "Renders nothing when there is no other theme to offer."
  @spec switcher(map()) :: Phoenix.LiveView.Rendered.t()
  def switcher(assigns) do
    assigns = assign(assigns, :options, assigns.options || active_options())

    ~H"""
    <nav
      :if={length(@options) > 1}
      class="demo-theme-switcher"
      data-testid="demo-theme-switcher"
      aria-label={dgettext("booking", "Demo themes")}
    >
      <span class="demo-theme-switcher__label">{dgettext("booking", "Try another theme")}</span>
      <ul class="demo-theme-switcher__list">
        <li :for={{name, id} <- @options}>
          <a
            href={PathHandlers.with_query(@base_path, %{"theme" => id})}
            class={[
              "demo-theme-switcher__link",
              id == @theme_id && "demo-theme-switcher__link--current"
            ]}
            aria-current={id == @theme_id && "page"}
            data-theme-option={id}
          >
            {name}
          </a>
        </li>
      </ul>
    </nav>
    """
  end

  @doc """
  The `{name, id}` pairs of the themes whose status is `:active`, in numeric
  id order. A beta or deprecated theme is not offered in a demo. Takes the
  registry's definitions by default; passing them in is for tests.
  """
  @spec active_options(%{atom() => map()}) :: [{String.t(), String.t()}]
  def active_options(themes \\ Registry.all_themes()) do
    themes
    |> Map.filter(fn {_key, theme} -> theme.status == :active end)
    |> ThemeInfo.theme_options()
  end
end
