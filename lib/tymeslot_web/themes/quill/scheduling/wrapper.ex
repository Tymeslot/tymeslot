defmodule TymeslotWeb.Themes.Quill.Scheduling.Wrapper do
  @moduledoc """
  Wrapper component for Quill theme that handles theme customizations.
  """
  use Phoenix.Component

  alias TymeslotWeb.Themes.Shared.Customization.Video, as: VideoHelpers

  import TymeslotWeb.Themes.Shared.Customization.Helpers

  @doc """
  Renders the Quill theme wrapper with custom styles and background.
  """
  @spec quill_wrapper(map()) :: Phoenix.LiveView.Rendered.t()
  def quill_wrapper(assigns) do
    # Check if video background is active
    has_video_background =
      assigns[:theme_customization] &&
        get_background_type(assigns[:theme_customization]) == "video"

    assigns = assign(assigns, :has_video_background, has_video_background)

    ~H"""
    <div class="quill-theme-wrapper theme-1">
      <!-- Render custom CSS if available -->
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
      
    <!-- Render background video if configured -->
      <%= if @has_video_background do %>
        <div class="video-background">
          <video autoplay muted loop playsinline class="video-background video">
            <% background_video_path = get_background_video_path(@theme_customization) %>
            <%= if background_video_path do %>
              <source src={"/uploads/#{background_video_path}"} type="video/mp4" />
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
      <% end %>
      
    <!-- Apply background styles to main gradient -->
      <div
        class={[
          "min-h-screen main-gradient flex flex-col",
          @has_video_background && "has-video-background"
        ]}
        style={
          if assigns[:theme_customization] && !@has_video_background,
            do: get_background_style(assigns[:theme_customization]),
            else: ""
        }
      >
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # Helper functions to safely get values from either struct or map
  defp get_background_type(%{background_type: bg_type}), do: bg_type
  defp get_background_type(%{"background_type" => bg_type}), do: bg_type
  defp get_background_type(_), do: nil

  defp get_background_video_path(%{background_video_path: path}), do: path
  defp get_background_video_path(%{"background_video_path" => path}), do: path
  defp get_background_video_path(_), do: nil

  defp get_background_value(%{background_value: value}), do: value
  defp get_background_value(%{"background_value" => value}), do: value
  defp get_background_value(_), do: nil
end
