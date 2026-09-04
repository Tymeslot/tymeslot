defmodule TymeslotWeb.Themes.Quill.Scheduling.Wrapper do
  @moduledoc """
  Wrapper component for Quill theme that handles theme customizations.
  """
  use Phoenix.Component

  alias Tymeslot.Locales

  import TymeslotWeb.Components.BackgroundMotionToggle,
    only: [background_motion_toggle: 1]

  import TymeslotWeb.Themes.Shared.Customization.Helpers
  import TymeslotWeb.Themes.Shared.VideoSources, only: [video_sources: 1]
  import TymeslotWeb.Components.LanguageSwitcher

  attr :theme_customization, :map, default: nil
  attr :custom_css, :string, default: nil
  attr :locale, :string, default: nil
  attr :current_state, :atom, default: nil
  attr :language_dropdown_open, :boolean, default: nil
  attr :organizer_user_id, :integer, default: nil
  attr :should_show_branding, :boolean, default: false
  attr :show_language_switcher, :boolean, default: nil
  slot :inner_block, required: true

  @doc """
  Renders the Quill theme wrapper with custom styles and background.
  """
  @spec quill_wrapper(map()) :: Phoenix.LiveView.Rendered.t()
  def quill_wrapper(assigns) do
    assigns = prepare_wrapper_assigns(assigns)

    ~H"""
    <div class="quill-theme-wrapper theme-1" data-locale={assigns[:locale]}>
      <%= if assigns[:custom_css] && assigns[:custom_css] != "" do %>
        <style type="text/css">
          :root {
            <%= Phoenix.HTML.raw(@custom_css) %>
            <%= if @has_video_background do %>
              --has-video-background: 1;
            <% end %>
          }
        </style>
      <% else %>
        <%= if @has_video_background do %>
          <style type="text/css">
            :root {
              --has-video-background: 1;
            }
          </style>
        <% end %>
      <% end %>

      <%= if @has_video_background do %>
        <div class="video-background" id="quill-video-container" phx-hook="QuillVideo">
          <video
            autoplay
            muted
            loop
            playsinline
            preload="metadata"
            poster={@video_poster}
            class="video-background"
          >
            <.video_sources theme_customization={@theme_customization} />
          </video>
        </div>
        <.background_motion_toggle />
      <% end %>

      <div
        class={[
          "main-gradient theme-grid",
          @has_video_background && "has-video-background"
        ]}
        style={
          if assigns[:theme_customization] && !@has_video_background,
            do: get_background_style(assigns[:theme_customization]),
            else: ""
        }
      >
        <div class="content-area">
          <%= if assigns[:locale] && assigns[:language_dropdown_open] != nil do %>
            <div class={[
              "fixed top-6 right-6 z-50 language-switcher-wrapper",
              @show_language_switcher && "visible",
              !@show_language_switcher && "hidden"
            ]}>
              <.language_switcher
                locale={@locale}
                locales={Locales.supported()}
                dropdown_open={@language_dropdown_open}
                theme="quill"
              />
            </div>
          <% end %>

          {render_slot(@inner_block)}
        </div>

        {TymeslotWeb.Layouts.render_theme_extensions(assigns)}
      </div>
    </div>
    """
  end
end
