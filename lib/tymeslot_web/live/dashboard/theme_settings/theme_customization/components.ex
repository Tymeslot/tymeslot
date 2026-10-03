defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Components do
  @moduledoc """
  UI components for theme customization.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.ThemeCustomizations
  alias TymeslotWeb.Live.Scheduling.PreviewMode

  import TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.CurrentIndicator,
    only: [current_indicator: 1]

  import TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Pickers.ColorPicker,
    only: [color_picker: 1]

  import TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Pickers.ColourPickerWidget,
    only: [colour_picker_widget: 1]

  import TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Pickers.GradientPicker,
    only: [gradient_picker: 1]

  import TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Pickers.ImagePicker,
    only: [image_picker: 1]

  import TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Pickers.VideoPicker,
    only: [video_picker: 1]

  @spec toolbar(map()) :: Phoenix.LiveView.Rendered.t()
  def toolbar(assigns) do
    ~H"""
    <div class="flex flex-col md:flex-row md:items-center md:justify-between gap-6 mb-10">
      <.section_header
        icon="hero-paint-brush"
        title={dgettext("dashboard_appearance", "Customize Style")}
      />

      <div class="flex items-center justify-between gap-3 md:justify-start">
        <%= if @profile && @profile.username do %>
          <.action_link
            href={PreviewMode.owner_path(@profile.username, @profile.user_id, theme: @theme_id)}
            target="_blank"
            rel="noopener noreferrer"
            variant={:secondary}
            icon="hero-eye"
          >
            {dgettext("dashboard_appearance", "Live Preview")}
          </.action_link>
        <% end %>
        <.action_button
          variant={:outline}
          icon="hero-x-mark"
          phx-click="close_customization"
          phx-target={@parent_component}
        >
          {dgettext("dashboard_appearance", "Close")}
        </.action_button>
      </div>
    </div>
    """
  end

  @spec color_scheme_section(map()) :: Phoenix.LiveView.Rendered.t()
  def color_scheme_section(assigns) do
    ~H"""
    <.card
      title={dgettext("dashboard_appearance", "Color Palette")}
      description={
        dgettext(
          "dashboard_appearance",
          "Select the primary colors for your booking page interface."
        )
      }
    >
      <:actions>
        <% current_scheme = ThemeCustomizations.resolve_active_scheme(@customization, @presets) %>
        <% custom_selected = not is_nil(@customization.custom_palette_seed) %>
        <%= if current_scheme do %>
          <.current_indicator
            swatches={[
              current_scheme.colors.primary,
              current_scheme.colors.secondary,
              current_scheme.colors.accent
            ]}
            label={current_scheme.name}
            code={
              if custom_selected,
                do: String.upcase(@customization.custom_palette_seed)
            }
            highlighted={custom_selected}
          />
        <% end %>
        <button
          type="button"
          phx-click="theme:toggle_palette_picker"
          phx-target={@myself}
          aria-expanded={to_string(@palette_picker_open)}
          aria-controls="custom-palette-picker"
          class={[
            "flex items-center gap-2 px-3.5 py-2 rounded-token-xl border-2 text-token-2xs font-black uppercase tracking-widest transition-all duration-300",
            if(@palette_picker_open,
              do:
                "bg-turquoise-50 border-turquoise-300 text-turquoise-700 shadow-sm shadow-turquoise-500/10",
              else:
                "bg-tymeslot-50 border-transparent text-tymeslot-600 hover:bg-tymeslot-100 hover:border-tymeslot-200"
            )
          ]}
        >
          <.icon name="hero-swatch-mini" class="w-4 h-4" />
          <span>{dgettext("dashboard_appearance", "Custom")}</span>
          <.icon
            name="hero-chevron-down-mini"
            class={"w-4 h-4 transition-transform duration-300 #{if @palette_picker_open, do: "rotate-180"}"}
          />
        </button>
      </:actions>

      <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-4">
        <% active_scheme_id =
          if is_nil(@customization.custom_palette_seed), do: @customization.color_scheme %>
        <%= for {scheme_id, scheme} <- @presets.color_schemes do %>
          <button
            type="button"
            class={[
              "group/scheme relative flex flex-col items-center p-4 rounded-token-2xl border-2 transition-all duration-300",
              if(active_scheme_id == scheme_id,
                do: "bg-turquoise-50 border-turquoise-400 shadow-xl shadow-turquoise-500/10",
                else: "bg-white border-tymeslot-50 hover:border-turquoise-200 hover:shadow-lg"
              )
            ]}
            phx-click="theme:select_color_scheme"
            phx-value-scheme={scheme_id}
            phx-target={@myself}
          >
            <div class="flex items-center gap-2 mb-4 bg-tymeslot-50/50 p-2 rounded-token-xl group-hover/scheme:scale-110 transition-transform">
              <div
                class="w-6 h-6 rounded-full shadow-sm border border-white"
                style={"background-color: #{scheme.colors.primary}"}
              >
              </div>
              <div
                class="w-6 h-6 rounded-full shadow-sm border border-white"
                style={"background-color: #{scheme.colors.secondary}"}
              >
              </div>
              <div
                class="w-6 h-6 rounded-full shadow-sm border border-white"
                style={"background-color: #{scheme.colors.accent}"}
              >
              </div>
            </div>
            <p class={[
              "text-token-sm font-black uppercase tracking-widest transition-colors",
              if(active_scheme_id == scheme_id,
                do: "text-turquoise-700",
                else: "text-tymeslot-400 group-hover/scheme:text-tymeslot-600"
              )
            ]}>
              {scheme.name}
            </p>

            <%= if active_scheme_id == scheme_id do %>
              <div class="absolute top-2 right-2 w-6 h-6 bg-turquoise-500 text-white rounded-full flex items-center justify-center shadow-lg">
                <.icon name="hero-check-mini" class="w-4 h-4" />
              </div>
            <% end %>
          </button>
        <% end %>
      </div>

      <%= if not is_nil(@customization.custom_palette_seed) and @palette_picker_open do %>
        <div class="mt-6 animate-fade-in-up rounded-token-2xl border-2 border-tymeslot-50 bg-tymeslot-50/50 p-4">
          <.colour_picker_widget
            id="custom-palette-picker"
            target={@myself}
            initial_hex={@customization.custom_palette_seed}
            commit_event="theme:set_palette_seed"
          />
        </div>
      <% end %>
    </.card>
    """
  end

  @spec background_section(map()) :: Phoenix.LiveView.Rendered.t()
  def background_section(assigns) do
    ~H"""
    <.card
      title={dgettext("dashboard_appearance", "Background Design")}
      description={
        dgettext(
          "dashboard_appearance",
          "Choose a visual style that matches your professional identity."
        )
      }
    >
      <div class="space-y-10">
        <.segmented_control
          id="background-type"
          value={@browsing_type}
          on_change="theme:set_browsing_type"
          param="type"
          target={@myself}
          aria_label={dgettext("dashboard_appearance", "Background type")}
        >
          <:option
            :for={{type, icon, label} <- background_tabs()}
            value={type}
            label={label}
            icon={icon}
          />
        </.segmented_control>

        <div>
          <%= case @browsing_type do %>
            <% "gradient" -> %>
              <.gradient_picker customization={@customization} presets={@presets} myself={@myself} />
            <% "color" -> %>
              <.color_picker
                customization={@customization}
                myself={@myself}
                custom_picker_open={@custom_picker_open}
              />
            <% "image" -> %>
              <.image_picker
                customization={@customization}
                presets={@presets}
                uploads={@uploads}
                myself={@myself}
              />
            <% "video" -> %>
              <.video_picker
                customization={@customization}
                presets={@presets}
                uploads={@uploads}
                myself={@myself}
              />
          <% end %>
        </div>
      </div>
    </.card>
    """
  end

  defp background_tabs do
    [
      {"gradient", "hero-cube", dgettext("dashboard_appearance", "Gradient")},
      {"color", "hero-swatch", dgettext("dashboard_appearance", "Solid Color")},
      {"image", "hero-photo", dgettext("dashboard_appearance", "Image")},
      {"video", "hero-video-camera", dgettext("dashboard_appearance", "Video")}
    ]
  end
end
