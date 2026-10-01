defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.BackgroundPanel do
  @moduledoc """
  The dashboard panel for an `Options.Background` group: one tab per kind the
  group offers, each with its picker over the group's presets.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext
  use TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panel

  alias Tymeslot.ThemeCustomizations.Options.Background
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panel

  import TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Pickers.ColorPicker,
    only: [color_picker: 1]

  import TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Pickers.GradientPicker,
    only: [gradient_picker: 1]

  import TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Pickers.ImagePicker,
    only: [image_picker: 1]

  import TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Pickers.VideoPicker,
    only: [video_picker: 1]

  @impl Panel
  def render(assigns) do
    ~H"""
    <div class="card-glass">
      <div class="mb-8">
        <h3 class="text-token-xl font-black text-tymeslot-900 tracking-tight">
          {dgettext("dashboard_appearance", "Background Design")}
        </h3>
        <p class="text-token-sm text-tymeslot-500 font-bold mt-1">
          {dgettext(
            "dashboard_appearance",
            "Choose a visual style that matches your professional identity."
          )}
        </p>
      </div>

      <div class="space-y-10">
        <div class="grid grid-cols-2 sm:grid-cols-4 gap-2 bg-tymeslot-50/50 p-2 rounded-[1.5rem] border-2 border-tymeslot-50">
          <%= for {type, icon_path, label} <- background_tabs(@group.kinds) do %>
            <button
              type="button"
              class={[
                "flex items-center justify-center gap-2 px-4 py-3 rounded-token-2xl text-token-sm font-black uppercase tracking-widest transition-all duration-300 border-2 whitespace-nowrap",
                if(@browsing_type == type,
                  do:
                    "bg-white border-white text-turquoise-600 shadow-xl shadow-tymeslot-200/50 scale-[1.02]",
                  else:
                    "bg-transparent border-transparent text-tymeslot-400 hover:text-tymeslot-600 hover:bg-white/50"
                )
              ]}
              phx-click="theme:set_browsing_type"
              phx-value-option={@group.key}
              phx-value-type={type}
              phx-target={@myself}
            >
              <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d={icon_path} />
              </svg>
              <span>{label}</span>
            </button>
          <% end %>
        </div>

        <div>
          <%= case @browsing_type do %>
            <% "gradient" -> %>
              <.gradient_picker
                option={@group.key}
                customization={@customization}
                presets={Background.presets(@group, :gradient)}
                myself={@myself}
              />
            <% "color" -> %>
              <.color_picker
                option={@group.key}
                customization={@customization}
                myself={@myself}
                custom_picker_open={@custom_picker_open}
              />
            <% "image" -> %>
              <.image_picker
                option={@group.key}
                customization={@customization}
                presets={Background.presets(@group, :image)}
                uploads={@uploads}
                myself={@myself}
              />
            <% "video" -> %>
              <.video_picker
                option={@group.key}
                customization={@customization}
                presets={Background.presets(@group, :video)}
                uploads={@uploads}
                myself={@myself}
              />
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # The open tab follows the saved kind (on load, and after a save, which
  # always saves the chosen kind), falling back to the group's first kind.
  # The custom colour disclosure survives saves, so committing a colour does
  # not close it.
  @impl Panel
  def ui(group, customization, ui) do
    kinds = kind_names(group)
    saved = customization.settings["background_type"]

    %{
      browsing_type: if(saved in kinds, do: saved, else: List.first(kinds)),
      custom_picker_open: Map.get(ui, :custom_picker_open, false)
    }
  end

  @impl Panel
  def handle_ui("theme:set_browsing_type", %{"type" => type}, group, ui, _customization) do
    if type in kind_names(group), do: {:ui, %{ui | browsing_type: type}}, else: :ignore
  end

  def handle_ui("theme:toggle_custom_picker", _params, _group, ui, _customization),
    do: {:ui, %{ui | custom_picker_open: not ui.custom_picker_open}}

  def handle_ui(_event, _params, _group, _ui, _customization), do: :ignore

  @impl Panel
  def telemetry(_group, kind, value),
    do: {:background_changed, "background", %{type: kind, value: value}}

  defp kind_names(%{kinds: kinds}), do: Enum.map(kinds, &Atom.to_string/1)

  defp background_tabs(kinds) do
    declared = Enum.map(kinds, &Atom.to_string/1)
    Enum.filter(all_background_tabs(), fn {type, _icon, _label} -> type in declared end)
  end

  defp all_background_tabs do
    [
      {"gradient", "M20 7l-8-4-8 4m16 0l-8 4m8-4v10l-8 4m0-10L4 7m8 4v10M4 7v10l8 4",
       dgettext("dashboard_appearance", "Gradient")},
      {"color",
       "M7 21a4 4 0 01-4-4V5a2 2 0 012-2h4a2 2 0 012 2v12a4 4 0 01-4 4zm0 0h12a2 2 0 002-2v-4a6 6 0 00-3-5.197M11 3h8a2 2 0 012 2v4a6 6 0 01-3 5.197",
       dgettext("dashboard_appearance", "Solid Colour")},
      {"image",
       "M4 16l4.586-4.586a2 2 0 012.828 0L16 16m-2-2l1.586-1.586a2 2 0 012.828 0L20 14m-6-6h.01M6 20h12a2 2 0 002-2V6a2 2 0 00-2-2H6a2 2 0 00-2 2v12a2 2 0 002 2z",
       dgettext("dashboard_appearance", "Image")},
      {"video",
       "M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z",
       dgettext("dashboard_appearance", "Video")}
    ]
  end
end
