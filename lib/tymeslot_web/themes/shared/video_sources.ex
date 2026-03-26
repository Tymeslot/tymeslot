defmodule TymeslotWeb.Themes.Shared.VideoSources do
  @moduledoc """
  Shared component for rendering video source elements from theme customization.
  Handles both user-uploaded videos and preset videos.
  """

  use Phoenix.Component

  alias Tymeslot.DatabaseSchemas.ThemeCustomizationSchema
  alias TymeslotWeb.Themes.Shared.Customization.Video, as: VideoHelpers

  import TymeslotWeb.Themes.Shared.Customization.Helpers,
    only: [get_background_video_path: 1, get_background_value: 1]

  attr :theme_customization, :map, required: true

  @spec video_sources(map()) :: Phoenix.LiveView.Rendered.t()
  def video_sources(assigns) do
    # raw/1 is safe here: render_upload_video_sources internally calls
    # Validation.sanitize_path/1, and render_preset_video_sources uses
    # hardcoded preset filenames from ThemeCustomizationSchema.
    ~H"""
    <%= if (path = get_background_video_path(@theme_customization)) do %>
      {Phoenix.HTML.raw(VideoHelpers.render_upload_video_sources(path))}
    <% else %>
      <% bg = get_background_value(@theme_customization) %>
      <%= if bg && String.starts_with?(bg, "preset:") do %>
        <% preset = ThemeCustomizationSchema.video_presets()[bg] %>
        <%= if preset do %>
          {Phoenix.HTML.raw(VideoHelpers.render_preset_video_sources(preset.file))}
        <% end %>
      <% end %>
    <% end %>
    """
  end
end
