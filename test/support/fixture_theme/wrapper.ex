defmodule TymeslotWeb.Test.FixtureTheme.Scheduling.Wrapper do
  @moduledoc """
  The fixture theme's wrapper: the shared `ThemeShell` with no background
  and no page grid of its own. The chrome, the step and the theme
  extensions sit straight inside the booker root, which proves the shell's
  obligations need none of Quill's and Rhythm's layout. It renders the
  page's logo and cover media when the spec resolves them, which only the
  showcase theme's does, since it borrows these pages.
  """
  use Phoenix.Component

  alias Tymeslot.ThemeCustomizations.Tokens
  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Themes.Shared.Components.ThemeShell

  import TymeslotWeb.Themes.Shared.Customization.Helpers, only: [prepare_wrapper_assigns: 1]

  attr :theme_tokens, :any, default: nil
  attr :locale, :string, default: nil
  attr :current_state, :atom, default: nil
  attr :language_dropdown_open, :boolean, default: nil
  attr :organizer_user_id, :integer, default: nil
  attr :should_show_branding, :boolean, default: false
  attr :show_language_switcher, :boolean, default: nil
  attr :owner_preview, :boolean, default: false
  attr :demo_mode, :boolean, doc: "handed to the theme extensions only when given"
  slot :inner_block, required: true

  @spec fixture_wrapper(map()) :: Phoenix.LiveView.Rendered.t()
  def fixture_wrapper(assigns) do
    assigns =
      assigns
      |> prepare_wrapper_assigns()
      |> assign(
        theme_id: theme_id(),
        logo: media(assigns.theme_tokens, :logo),
        cover: media(assigns.theme_tokens, :cover)
      )

    ~H"""
    <ThemeShell.theme_shell
      class="fixture-theme-wrapper"
      locale={@locale}
      theme_tokens={@theme_tokens}
    >
      <ThemeShell.chrome
        language_class="fixture-theme-language"
        locale={@locale}
        language_dropdown_open={@language_dropdown_open}
        show_language_switcher={@show_language_switcher}
        owner_preview={@owner_preview}
      />
      <img :if={@cover} src={@cover.src} alt="" data-testid="theme-cover" />
      <img :if={@logo} src={@logo.src} alt="" data-testid="theme-logo" />
      {render_slot(@inner_block)}
      <ThemeShell.extensions
        theme_id={@theme_id}
        organizer_user_id={@organizer_user_id}
        should_show_branding={@should_show_branding}
        {Map.take(assigns, [:demo_mode])}
      />
    </ThemeShell.theme_shell>
    """
  end

  defp media(%Tokens{media: media}, key), do: media[key]
  defp media(_no_tokens, _key), do: nil

  defp theme_id do
    {:ok, id} = Catalog.key_to_id(:fixture)
    id
  end
end
