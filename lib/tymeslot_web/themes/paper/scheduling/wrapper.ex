defmodule TymeslotWeb.Themes.Paper.Scheduling.Wrapper do
  @moduledoc """
  Paper's wrapper: the shared `ThemeShell` on the tone's canvas. Paper has
  no background option, so nothing is drawn behind the card. Inside the
  shell, Paper's page grid (`.booker-page paper-page`, sized to content in an
  embed by its `iframe.css`) holds the content area, which starts with the
  shell's chrome (the language switcher's row is `paper-language`), and the
  theme extensions as its footer row.
  """
  use Phoenix.Component

  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Themes.Shared.Components.ThemeShell

  import TymeslotWeb.Themes.Shared.Customization.Helpers, only: [prepare_wrapper_assigns: 1]

  attr :theme_tokens, :any, default: nil
  attr :locale, :string, default: nil
  attr :current_state, :atom, default: nil

  attr :journey, :any,
    default: nil,
    doc: "the page's journey: its first moment shows the switcher"

  attr :language_dropdown_open, :boolean, default: nil
  attr :organizer_user_id, :integer, default: nil
  attr :should_show_branding, :boolean, default: false
  attr :show_language_switcher, :boolean, default: nil
  attr :owner_preview, :boolean, default: false
  attr :demo_mode, :boolean, doc: "handed to the theme extensions only when given"
  slot :inner_block, required: true

  @spec paper_wrapper(map()) :: Phoenix.LiveView.Rendered.t()
  def paper_wrapper(assigns) do
    assigns = assigns |> prepare_wrapper_assigns() |> assign(:theme_id, theme_id())

    ~H"""
    <ThemeShell.theme_shell
      class="paper-theme-wrapper"
      locale={@locale}
      theme_tokens={@theme_tokens}
    >
      <div class="booker-page paper-page">
        <div class="content-area">
          <ThemeShell.chrome
            language_class="paper-language"
            locale={@locale}
            language_dropdown_open={@language_dropdown_open}
            show_language_switcher={@show_language_switcher}
            owner_preview={@owner_preview}
          />
          {render_slot(@inner_block)}
        </div>
        <ThemeShell.extensions
          theme_id={@theme_id}
          organizer_user_id={@organizer_user_id}
          should_show_branding={@should_show_branding}
          {Map.take(assigns, [:demo_mode])}
        />
      </div>
    </ThemeShell.theme_shell>
    """
  end

  defp theme_id do
    {:ok, id} = Catalog.key_to_id(:paper)
    id
  end
end
