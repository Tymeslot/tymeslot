defmodule TymeslotWeb.Themes.Rhythm.Scheduling.Wrapper do
  @moduledoc """
  Wrapper component for Rhythm theme that handles theme customizations.
  """
  use Phoenix.Component

  import TymeslotWeb.Themes.Shared.Customization.Helpers
  import TymeslotWeb.Components.LanguageSwitcher
  alias TymeslotWeb.Themes.Shared.Customization.Video, as: VideoHelpers

  @doc """
  Renders the Rhythm theme wrapper with custom styles and background.
  """
  @spec rhythm_wrapper(map()) :: Phoenix.LiveView.Rendered.t()
  def rhythm_wrapper(assigns) do
    # Check if video background is active
    has_video_background =
      assigns[:theme_customization] &&
        get_background_type(assigns[:theme_customization]) == "video"

    assigns =
      assigns
      |> assign(:has_video_background, has_video_background)
      |> assign(:video_poster, get_background_video_poster(assigns[:theme_customization]))

    ~H"""
    <div class="rhythm-theme-wrapper theme-2" data-locale={assigns[:locale]}>
      <!-- Render custom CSS if available -->
      <%= if assigns[:custom_css] && assigns[:custom_css] != "" do %>
        <style type="text/css">
          :root {
            <%= Phoenix.HTML.raw(@custom_css) %>
          }
        </style>
      <% end %>

    <!-- Render background based on type -->
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
              <% background_video_path = get_background_video_path(@theme_customization) %>
              <%= if background_video_path do %>
                <% sanitized_path = sanitize_path(background_video_path) %>
                <source src={"/uploads/#{sanitized_path}"} type="video/mp4" />
              <% else %>
                <!-- Handle preset videos -->
                <% background_value = get_background_value(@theme_customization) %>
                <%= if background_value && String.starts_with?(background_value, "preset:") do %>
                  <% preset_id = background_value %>
                  <% preset =
                    Tymeslot.DatabaseSchemas.ThemeCustomizationSchema.video_presets()[preset_id] %>
                  <%= if preset do %>
                    {Phoenix.HTML.raw(VideoHelpers.render_preset_video_sources(preset.file))}
                  <% end %>
                <% end %>
              <% end %>
            </video>
            <!-- Second video for crossfade -->
            <video
              id="rhythm-background-video-2"
              muted
              loop
              playsinline
              poster={@video_poster}
              class="video-background-video inactive"
              preload="metadata"
            >
              <% background_video_path = get_background_video_path(@theme_customization) %>
              <%= if background_video_path do %>
                <% sanitized_path = sanitize_path(background_video_path) %>
                <source src={"/uploads/#{sanitized_path}"} type="video/mp4" />
              <% else %>
                <!-- Handle preset videos -->
                <% background_value = get_background_value(@theme_customization) %>
                <%= if background_value && String.starts_with?(background_value, "preset:") do %>
                  <% preset_id = background_value %>
                  <% preset =
                    Tymeslot.DatabaseSchemas.ThemeCustomizationSchema.video_presets()[preset_id] %>
                  <%= if preset do %>
                    {Phoenix.HTML.raw(VideoHelpers.render_preset_video_sources(preset.file))}
                  <% end %>
                <% end %>
              <% end %>
            </video>
          </div>
        <% assigns[:theme_customization] && get_background_type(assigns[:theme_customization]) in ["gradient", "color", "image"] -> %>
          <div class="video-background-container" style={get_background_style(assigns[:theme_customization])}>
          </div>
        <% true -> %>
          <!-- Default gradient background -->
          <div class="video-background-container"></div>
      <% end %>

      <!-- Main wrapper -->
      <div class="video-background-theme theme-grid">
        <div class="content-area">
          <!-- Language Switcher -->
          <%= if assigns[:locale] && assigns[:language_dropdown_open] != nil do %>
            <div class="absolute top-6 right-6 z-50 language-switcher-container">
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
