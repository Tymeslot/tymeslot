defmodule TymeslotWeb.Themes.Rhythm.Scheduling.Wrapper do
  @moduledoc """
  Wrapper component for Rhythm theme that handles theme customizations.
  """
  use Phoenix.Component

  import TymeslotWeb.Themes.Shared.Customization.Helpers
  import TymeslotWeb.Components.LanguageSwitcher
  import TymeslotWeb.Themes.Shared.VideoSources, only: [video_sources: 1]

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
  Renders the Rhythm theme wrapper with custom styles and background.
  """
  @spec rhythm_wrapper(map()) :: Phoenix.LiveView.Rendered.t()
  def rhythm_wrapper(assigns) do
    assigns = prepare_wrapper_assigns(assigns)

    ~H"""
    <div class="rhythm-theme-wrapper theme-2" data-locale={assigns[:locale]}>
      <%= if assigns[:custom_css] && assigns[:custom_css] != "" do %>
        <style type="text/css">
          :root {
            <%= Phoenix.HTML.raw(@custom_css) %>
          }
        </style>
      <% end %>

      <%= cond do %>
        <% @has_video_background -> %>
          <div class="video-background-container" id="rhythm-video-container" phx-hook="RhythmVideo">
            <video
              id="rhythm-background-video-1"
              autoplay
              muted
              loop
              playsinline
              poster={@video_poster}
              class="video-background-video active"
              preload="metadata"
            >
              <.video_sources theme_customization={@theme_customization} />
            </video>
            <video
              id="rhythm-background-video-2"
              muted
              loop
              playsinline
              poster={@video_poster}
              class="video-background-video inactive"
              preload="none"
            >
              <.video_sources theme_customization={@theme_customization} />
            </video>
          </div>
        <% assigns[:theme_customization] && get_background_type(assigns[:theme_customization]) in ["gradient", "color", "image"] -> %>
          <div class="video-background-container" style={get_background_style(assigns[:theme_customization])}>
          </div>
        <% true -> %>
          <div class="video-background-container"></div>
      <% end %>

      <div class="video-background-theme theme-grid">
        <div class="content-area">
          <%= if assigns[:locale] && assigns[:language_dropdown_open] != nil do %>
            <div class={[
              "language-switcher-container",
              @show_language_switcher && "visible",
              !@show_language_switcher && "hidden"
            ]}>
              <.language_switcher
                locale={@locale}
                locales={TymeslotWeb.Themes.Shared.LocaleHandler.get_locales_with_metadata()}
                dropdown_open={@language_dropdown_open}
                theme="rhythm"
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
