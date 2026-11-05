defmodule TymeslotWeb.Themes.Shared.Components.ThemeShell do
  @moduledoc """
  What every booking page carries, whatever the theme's layout. Three
  function components, each rendered once by the theme's wrapper:

    * `theme_shell/1`: the theme's outermost element, marked
      `data-booker-root` (the element the shared embed rules in
      `shared/embed.css` size to content), holding the organiser's
      customisation as a `<style>` block (`ThemeStyle`), the preloads of
      the page's web fonts (`FontPreload`: the font the customisation
      chose, `Tokens.media[:font]`, else the theme's `default_font`), the
      theme's background (`:background` slot) and then the theme's own
      markup;
    * `chrome/1`: the owner-preview notice and the language switcher, which
      the theme places at the top of its content. A hidden switcher's
      container carries `theme-shell__language--hidden` next to Tailwind's
      `hidden`, for a theme that must hide it with its own rule;
    * `extensions/1`: the extensions configured under `:theme_extensions`
      (on the managed instance, the branding banner and the analytics
      beacon), which the theme places after its content. They receive
      `theme_id`, `organizer_user_id`, `should_show_branding`, and
      `demo_mode` when the page assigned one.

  Everything between them is the theme's: the shipped themes lay their pages
  out as a grid (`.booker-page`) holding a content area and the extensions
  as its footer row; the fixture theme puts all three straight inside the
  root.

  After the extensions, and outside their `show_extensions` guard, every
  wrapper renders the organiser's legal links
  (`Shared.Components.LegalLinks.footer/1`). The wrapper draws it rather
  than `theme_shell/1`, because the shell's last child is the theme's own
  page grid, sized to the viewport: a footer after it would fall below the
  fold and off the grid's background, so it goes in the grid instead.

  `booker_hook_classes_test.exs` holds every registered theme's booking page
  to the obligations.
  """

  use Phoenix.Component

  alias Tymeslot.Locales
  alias TymeslotWeb.Layouts
  alias TymeslotWeb.Themes.Shared.Components.CalendarRefusedNotice
  alias TymeslotWeb.Themes.Shared.FontPreload
  alias TymeslotWeb.Themes.Shared.ThemeStyle

  import TymeslotWeb.Components.LanguageSwitcher, only: [language_switcher: 1]
  import TymeslotWeb.Themes.Shared.Components.PreviewNotice, only: [banner: 1]

  attr :class, :any, required: true, doc: "classes on the outermost element"
  attr :locale, :string, default: nil
  attr :theme_tokens, :any, default: nil, doc: "the page's `%Tokens{}`, or nil for none"

  attr :default_font, :string,
    default: nil,
    doc:
      "the font id the theme's stylesheet sets its text in, for a theme with no font option " <>
        "(`--theme-font-family` in its `variables.css`); a font the customisation chose wins"

  slot :background, doc: "the theme's background, rendered before its markup"
  slot :inner_block, required: true

  @doc "The theme's outermost element: the booker root, its colours and its background."
  @spec theme_shell(map()) :: Phoenix.LiveView.Rendered.t()
  def theme_shell(assigns) do
    assigns = assign(assigns, :font, chosen_font(assigns.theme_tokens) || assigns.default_font)

    ~H"""
    <div class={@class} data-locale={@locale} data-booker-root>
      <ThemeStyle.theme_style tokens={@theme_tokens} />
      <FontPreload.links font={@font} locale={@locale} />

      {render_slot(@background)}

      {render_slot(@inner_block)}
    </div>
    """
  end

  defp chosen_font(%{media: %{font: font}}), do: font
  defp chosen_font(_tokens), do: nil

  attr :language_class, :any, required: true, doc: "classes on the language switcher's container"
  attr :locale, :string, default: nil
  attr :language_dropdown_open, :boolean, default: nil
  attr :show_language_switcher, :boolean, default: false
  attr :owner_preview, :boolean, default: false

  attr :refused_calendars, :list,
    default: [],
    doc: "names of the organiser's refused calendars, given only when the organiser is viewing"

  @doc """
  The owner-preview notice, the organiser's refused-calendar notice and the
  language switcher. The switcher renders
  only when the page has a locale and tracks its dropdown; a page that
  decided not to show it keeps the container, hidden.
  """
  @spec chrome(map()) :: Phoenix.LiveView.Rendered.t()
  def chrome(assigns) do
    ~H"""
    <.banner owner_preview={@owner_preview} />
    <CalendarRefusedNotice.notice names={@refused_calendars} />
    <%= if @locale && @language_dropdown_open != nil do %>
      <div class={[
        @language_class,
        @show_language_switcher && "visible",
        !@show_language_switcher && "hidden theme-shell__language--hidden"
      ]}>
        <.language_switcher
          locale={@locale}
          locales={Locales.supported()}
          dropdown_open={@language_dropdown_open}
        />
      </div>
    <% end %>
    """
  end

  attr :theme_id, :string, required: true, doc: "the rendering theme's catalogue id"
  attr :organizer_user_id, :integer, default: nil
  attr :should_show_branding, :boolean, default: false
  attr :demo_mode, :boolean, doc: "handed to the extensions only when given"

  @doc "The configured theme extensions, handed this component's assigns."
  @spec extensions(map()) :: Phoenix.LiveView.Rendered.t()
  def extensions(assigns) do
    ~H"""
    {Layouts.render_theme_extensions(assigns)}
    """
  end

  @doc """
  An inline style as attributes to spread onto an element: none at all for
  `nil`, rather than the empty attribute `style={nil}` can leave, and the
  style as given otherwise.
  """
  @spec style_attrs(String.t() | nil) :: keyword()
  def style_attrs(nil), do: []
  def style_attrs(style), do: [style: style]
end
