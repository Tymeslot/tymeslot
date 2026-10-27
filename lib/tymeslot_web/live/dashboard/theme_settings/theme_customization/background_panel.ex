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
        <%!-- The group's key travels with the chosen type, so the event
             reaches this group's panel. --%>
        <.segmented_control
          id={"background-type-#{@group.key}"}
          value={@browsing_type}
          on_change="theme:set_browsing_type"
          param="type"
          values={%{option: @group.key}}
          target={@myself}
          aria_label={dgettext("dashboard_appearance", "Background type")}
        >
          <:option
            :for={{type, icon, label} <- background_tabs(@group.kinds)}
            value={type}
            label={label}
            icon={icon}
          />
        </.segmented_control>

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
    </.card>
    """
  end

  # On load the open tab follows the saved kind, falling back to the group's
  # first kind. After a save it stays where the organiser is: every choice is
  # made from the open tab, and removing an upload that is not on show (or
  # one that is, which falls back to the default) must not move them away
  # from it. The custom colour disclosure survives saves, so committing a
  # colour does not close it.
  @impl Panel
  def ui(group, customization, ui) do
    kinds = kind_names(group)
    saved = customization.settings["background_type"]

    %{
      browsing_type: browsing_type(Map.get(ui, :browsing_type), saved, kinds),
      custom_picker_open: Map.get(ui, :custom_picker_open, false)
    }
  end

  defp browsing_type(open, saved, kinds) do
    cond do
      open in kinds -> open
      saved in kinds -> saved
      true -> List.first(kinds)
    end
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
      {"gradient", "hero-cube", dgettext("dashboard_appearance", "Gradient")},
      {"color", "hero-swatch", dgettext("dashboard_appearance", "Solid Colour")},
      {"image", "hero-photo", dgettext("dashboard_appearance", "Image")},
      {"video", "hero-video-camera", dgettext("dashboard_appearance", "Video")}
    ]
  end
end
