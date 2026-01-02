defmodule TymeslotWeb.Themes.Rhythm.Scheduling.Wrapper do
  @moduledoc """
  Wrapper component for Rhythm theme that handles theme customizations.
  """
  use Phoenix.Component

  import TymeslotWeb.Themes.Shared.Customization.Helpers
  alias TymeslotWeb.Themes.Shared.Customization.Video, as: VideoHelpers

  @doc """
  Renders the Rhythm theme wrapper with custom styles and background.
  """
  @spec rhythm_wrapper(map()) :: Phoenix.LiveView.Rendered.t()
  def rhythm_wrapper(assigns) do
    ~H"""
    <div class="rhythm-theme-wrapper theme-2">
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
        <% @theme_customization && @theme_customization.background_type == "video" -> %>
          <div class="video-background-container" id="rhythm-video-container" phx-hook="RhythmVideo">
            <video
              id="rhythm-background-video-1"
              autoplay
              muted
              loop
              playsinline
              class="video-background-video active"
              preload="metadata"
            >
              <%= if @theme_customization.background_video_path do %>
                <source
                  src={"/uploads/#{@theme_customization.background_video_path}"}
                  type="video/mp4"
                />
              <% else %>
                <!-- Handle preset videos -->
                <%= if @theme_customization.background_value && String.starts_with?(@theme_customization.background_value, "preset:") do %>
                  <% preset_id = @theme_customization.background_value %>
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
              class="video-background-video inactive"
              preload="metadata"
            >
              <%= if @theme_customization.background_video_path do %>
                <source
                  src={"/uploads/#{@theme_customization.background_video_path}"}
                  type="video/mp4"
                />
              <% else %>
                <!-- Handle preset videos -->
                <%= if @theme_customization.background_value && String.starts_with?(@theme_customization.background_value, "preset:") do %>
                  <% preset_id = @theme_customization.background_value %>
                  <% preset =
                    Tymeslot.DatabaseSchemas.ThemeCustomizationSchema.video_presets()[preset_id] %>
                  <%= if preset do %>
                    {Phoenix.HTML.raw(VideoHelpers.render_preset_video_sources(preset.file))}
                  <% end %>
                <% end %>
              <% end %>
            </video>
          </div>
        <% @theme_customization && @theme_customization.background_type in ["gradient", "color", "image"] -> %>
          <div class="video-background-container" style={get_wrapper_style(assigns)}></div>
        <% true -> %>
          <!-- Default gradient background -->
          <div class="video-background-container"></div>
      <% end %>
      
    <!-- Main wrapper -->
      <div class="video-background-theme">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # Private helpers

  defp get_wrapper_style(assigns) do
    case assigns[:theme_customization] do
      nil -> ""
      customization -> get_background_style(customization)
    end
  end
end
