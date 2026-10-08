defmodule TymeslotWeb.Themes.Quill.Scheduling.Wrapper do
  @moduledoc """
  The Quill theme's wrapper: its video or gradient background, and its page
  grid (`.booker-page`, sized to content in an embed by its `iframe.css`)
  holding the content area and the theme extensions as its footer row,
  inside the shared `ThemeShell`.
  """
  use Phoenix.Component

  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Themes.Shared.Components.ThemeShell
  alias TymeslotWeb.Themes.Shared.ThemeStyle

  import TymeslotWeb.Components.BackgroundMotionToggle,
    only: [background_motion_toggle: 1]

  import TymeslotWeb.Themes.Shared.Customization.Helpers, only: [prepare_wrapper_assigns: 1]
  import TymeslotWeb.Themes.Shared.VideoSources, only: [video_sources: 1]

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

  @doc """
  Renders the Quill theme wrapper with custom styles and background.
  """
  @spec quill_wrapper(map()) :: Phoenix.LiveView.Rendered.t()
  def quill_wrapper(assigns) do
    assigns = assigns |> prepare_wrapper_assigns() |> assign(:theme_id, theme_id())

    ~H"""
    <ThemeShell.theme_shell
      class="quill-theme-wrapper"
      locale={@locale}
      theme_tokens={@theme_tokens}
    >
      <:background :if={@has_video_background}>
        <div class="video-background" id="quill-video-container" phx-hook="QuillVideo">
          <video
            autoplay
            muted
            loop
            playsinline
            preload="metadata"
            poster={@background.poster}
            class="video-background"
          >
            <.video_sources sources={@background.sources} />
          </video>
        </div>
        <.background_motion_toggle />
      </:background>
      <div
        class={grid_class(@has_video_background)}
        {ThemeShell.style_attrs(ThemeStyle.inline_background(@background))}
      >
        <div class="content-area">
          <ThemeShell.chrome
            language_class="absolute top-6 right-6 z-50 language-switcher-wrapper"
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

  # Built outside the template: a class list starting with a literal string
  # renders a trailing space when the rest is false.
  defp grid_class(has_video_background) do
    ["booker-page main-gradient theme-grid", has_video_background && "has-video-background"]
  end

  defp theme_id do
    {:ok, id} = Catalog.key_to_id(:quill)
    id
  end
end
