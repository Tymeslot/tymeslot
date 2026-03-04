defmodule TymeslotWeb.Themes.Quill.Scheduling.Wrapper do
  @moduledoc """
  Wrapper component for Quill theme that handles theme customizations.
  """
  use Phoenix.Component

  alias TymeslotWeb.Themes.Shared.Customization.Video, as: VideoHelpers

  import TymeslotWeb.Themes.Shared.Customization.Helpers
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
        <div class="video-background" id="quill-video-container" phx-hook="QuillVideo">
          <video autoplay muted loop playsinline poster={@video_poster} class="video-background video">
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
      <% end %>

      <!-- Apply background styles to main gradient -->
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
          <!-- Language Switcher -->
          <%= if assigns[:locale] && assigns[:language_dropdown_open] != nil do %>
            <div class={[
              "fixed top-6 right-6 z-50 language-switcher-wrapper",
              @show_language_switcher && "visible",
              !@show_language_switcher && "hidden"
            ]}>
              <.language_switcher
                locale={@locale}
                locales={TymeslotWeb.Themes.Shared.LocaleHandler.get_locales_with_metadata()}
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
