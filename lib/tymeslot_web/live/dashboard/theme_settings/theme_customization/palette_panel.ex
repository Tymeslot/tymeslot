defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.PalettePanel do
  @moduledoc """
  The dashboard panel for an `Options.Palette` group: the group's preset
  schemes and a custom seed colour.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext
  use TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panel

  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panel

  import TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.CurrentIndicator,
    only: [current_indicator: 1]

  import TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Pickers.ColourPickerWidget,
    only: [colour_picker_widget: 1]

  @impl Panel
  def render(assigns) do
    ~H"""
    <div class="card-glass">
      <div class="flex flex-col sm:flex-row sm:items-center justify-between mb-8 gap-4">
        <div>
          <h3 class="text-token-xl font-black text-tymeslot-900 tracking-tight">
            {dgettext("dashboard_appearance", "Colour Palette")}
          </h3>
          <p class="text-token-sm text-tymeslot-500 font-bold mt-1">
            {dgettext(
              "dashboard_appearance",
              "Select the primary colours for your booking page interface."
            )}
          </p>
        </div>

        <div class="flex flex-wrap items-center gap-3">
          <% current_scheme = Palette.resolve(@customization.settings, @group) %>
          <% custom_selected = not is_nil(@customization.settings["custom_palette_seed"]) %>
          <%= if current_scheme do %>
            <.current_indicator
              swatches={
                if custom_selected,
                  do: primary_swatches(current_scheme),
                  else: swatches(current_scheme, @group)
              }
              label={scheme_name(current_scheme)}
              code={
                if custom_selected,
                  do: String.upcase(@customization.settings["custom_palette_seed"])
              }
              highlighted={custom_selected}
            />
          <% end %>
          <button
            type="button"
            phx-click="theme:toggle_palette_picker"
            phx-value-option={@group.key}
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
        </div>
      </div>

      <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-4">
        <% active_scheme_id =
          if is_nil(@customization.settings["custom_palette_seed"]),
            do: @customization.settings["color_scheme"] %>
        <%!-- In the group's order, the theme's own (its default first where
        the spec puts it), as onboarding shows them.
        The param is named `choice` rather than `value`, because LiveView's
        client serialisation reads a button's native `value` IDL property and
        would overwrite `phx-value-value` with the empty string. --%>
        <%= for {scheme_id, scheme} <- Palette.schemes(@group) do %>
          <button
            type="button"
            class={[
              "group/scheme relative flex flex-col items-center p-4 rounded-token-2xl border-2 transition-all duration-300",
              if(active_scheme_id == scheme_id,
                do: "bg-turquoise-50 border-turquoise-400 shadow-xl shadow-turquoise-500/10",
                else: "bg-white border-tymeslot-50 hover:border-turquoise-200 hover:shadow-lg"
              )
            ]}
            phx-click="theme:set_option"
            phx-value-option={@group.key}
            phx-value-field="scheme"
            phx-value-choice={scheme_id}
            phx-target={@myself}
          >
            <% backing = swatch_backing(scheme, @group) %>
            <div
              class={[
                "flex items-center gap-2 mb-4 p-2 rounded-token-xl group-hover/scheme:scale-110 transition-transform",
                if(backing, do: "ring-1 ring-tymeslot-100", else: "bg-tymeslot-50/50")
              ]}
              {backing_style(backing)}
              data-testid="scheme-swatches"
            >
              <div
                :for={colour <- swatches(scheme, @group)}
                class="w-6 h-6 rounded-full shadow-sm border border-white"
                style={"background-color: #{colour}"}
              >
              </div>
            </div>
            <p class={[
              "text-token-sm font-black uppercase tracking-widest transition-colors",
              if(active_scheme_id == scheme_id,
                do: "text-turquoise-700",
                else: "text-tymeslot-500 group-hover/scheme:text-tymeslot-600"
              )
            ]}>
              {scheme_name(scheme)}
            </p>

            <%= if active_scheme_id == scheme_id do %>
              <div class="absolute top-2 right-2 w-6 h-6 bg-turquoise-500 text-white rounded-full flex items-center justify-center shadow-lg">
                <.icon name="hero-check-mini" class="w-4 h-4" />
              </div>
            <% end %>
          </button>
        <% end %>
      </div>

      <%= if not is_nil(@customization.settings["custom_palette_seed"]) and @palette_picker_open do %>
        <div class="mt-6 animate-fade-in-up rounded-token-2xl border-2 border-tymeslot-50 bg-tymeslot-50/50 p-4">
          <.colour_picker_widget
            id="custom-palette-picker"
            target={@myself}
            initial_hex={@customization.settings["custom_palette_seed"]}
            commit_event="theme:set_option"
            commit_params={%{option: @group.key, field: "seed"}}
          />
        </div>
      <% end %>
    </div>
    """
  end

  # The seed picker is open exactly while a seed drives the palette, both on
  # load and after a save: choosing a scheme drops the seed and closes it.
  @impl Panel
  def ui(_group, customization, _ui),
    do: %{palette_picker_open: not is_nil(customization.settings["custom_palette_seed"])}

  # "Custom" with no seed stored writes the default seed, which opens the
  # picker through ui/3; with a seed it only shows or hides the picker.
  @impl Panel
  def handle_ui("theme:toggle_palette_picker", _params, _group, ui, customization) do
    if is_nil(customization.settings["custom_palette_seed"]),
      do: {:set, "seed", ThemeCustomizations.default_custom_palette_seed()},
      else: {:ui, %{ui | palette_picker_open: not ui.palette_picker_open}}
  end

  def handle_ui(_event, _params, _group, _ui, _customization), do: :ignore

  # Event names and rate-limit labels as they were before the single event.
  @impl Panel
  def telemetry(_group, "seed", value),
    do: {:palette_seed_changed, "palette_seed", %{seed: value}}

  def telemetry(_group, _field, value),
    do: {:color_scheme_changed, "color_scheme", %{scheme_id: value}}

  # The three dots drawn for a scheme. The tones of a `follow_os` group share
  # one primary family by design, so their primary, secondary and accent look
  # the same; they differ in their grounds, so a tone shows its light ground,
  # its secondary text and its dark ground. Any other scheme (and a tone
  # without `dark_colors`) shows its primary, secondary and accent.
  defp swatches(%{colors: colors, dark_colors: %{background: dark_background}}, %{follow_os: true}),
       do: [colors.background, colors.text_secondary, dark_background]

  defp swatches(scheme, _group), do: primary_swatches(scheme)

  # The ground a scheme card's dots sit on. A tone's swatches already show its
  # grounds, so it keeps the panel's neutral backing; any other scheme's dots
  # sit on its own background, so a dark scheme reads dark.
  defp swatch_backing(%{dark_colors: %{background: _dark}}, %{follow_os: true}), do: nil
  defp swatch_backing(%{colors: %{background: background}}, _group), do: background
  defp swatch_backing(_scheme, _group), do: nil

  # No `style` attribute at all without a backing, rather than the empty one
  # HEEx renders for `style={nil}`.
  defp backing_style(nil), do: []
  defp backing_style(background), do: [style: "background-color: #{background}"]

  defp primary_swatches(%{colors: colors}),
    do: [colors.primary, colors.secondary, colors.accent]

  # A tone's name is registered for extraction in `Presets.ColourSchemes`;
  # the older schemes' names have no entry and come back as they are.
  defp scheme_name(%{name: name}),
    do: Gettext.dgettext(TymeslotWeb.Gettext, "dashboard_appearance", name)
end
