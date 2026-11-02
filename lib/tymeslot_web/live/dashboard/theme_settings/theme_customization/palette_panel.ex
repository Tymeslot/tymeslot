defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.PalettePanel do
  @moduledoc """
  The dashboard panel for an `Options.Palette` group: the group's preset
  schemes and a custom seed colour.

  In a `follow_os` group (Paper's) a scheme with a dark set is drawn as a
  small page in its light set beside the same page in its dark set, since
  the visitor may see either; any other scheme is drawn as dots of its
  colours.
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
    <.card
      title={dgettext("dashboard_appearance", "Colour Palette")}
      description={description(@group)}
    >
      <:actions>
        <% current_scheme = Palette.resolve(@customization.settings, @group) %>
        <% custom_selected = not is_nil(@customization.settings["custom_palette_seed"]) %>
        <%= if current_scheme do %>
          <.current_indicator
            swatches={primary_swatches(current_scheme)}
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
      </:actions>

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
            <.tone_preview :if={tone?(scheme, @group)} scheme={scheme} />
            <% backing = swatch_backing(scheme) %>
            <div
              :if={not tone?(scheme, @group)}
              class={[
                "flex items-center gap-2 mb-4 p-2 rounded-token-xl group-hover/scheme:scale-110 transition-transform",
                if(backing, do: "ring-1 ring-tymeslot-100", else: "bg-tymeslot-50/50")
              ]}
              {backing_style(backing)}
              data-testid="scheme-swatches"
            >
              <div
                :for={colour <- primary_swatches(scheme)}
                class="w-6 h-6 rounded-token-full shadow-sm border border-white"
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
              <div class="absolute top-2 right-2 w-6 h-6 bg-turquoise-500 text-white rounded-token-full flex items-center justify-center shadow-lg">
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
    </.card>
    """
  end

  attr :scheme, :map, required: true

  # A scheme as a page: its ground, a card on it, a line of text and a button
  # in its primary, in the light set on the left and the dark set on the right.
  defp tone_preview(assigns) do
    ~H"""
    <div
      class="flex w-full h-20 mb-4 rounded-token-xl overflow-hidden ring-1 ring-tymeslot-100 group-hover/scheme:scale-105 transition-transform"
      data-testid="tone-preview"
      aria-hidden="true"
    >
      <div
        :for={colours <- [@scheme.colors, @scheme.dark_colors]}
        class="flex-1 p-2.5"
        style={"background-color: #{colours.background}"}
      >
        <div
          class="h-full rounded-token-md p-2 flex flex-col justify-center gap-1.5"
          style={"background-color: #{colours.surface}"}
        >
          <div class="h-1.5 w-3/4 rounded-token-full" style={"background-color: #{colours.text}"}>
          </div>
          <div
            class="h-1.5 w-1/2 rounded-token-full"
            style={"background-color: #{colours.text_secondary}"}
          >
          </div>
          <div class="h-2.5 w-2/3 rounded-token-sm" style={"background-color: #{colours.primary}"}>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # A scheme without `dark_colors` falls back to the dots.
  defp tone?(scheme, group),
    do: Map.get(group, :follow_os, false) and Map.has_key?(scheme, :dark_colors)

  defp description(group) do
    if Map.get(group, :follow_os, false),
      do:
        dgettext(
          "dashboard_appearance",
          "The colours of your booking page, shown here light and dark. Colour Mode decides which one visitors see."
        ),
      else:
        dgettext(
          "dashboard_appearance",
          "Select the primary colours for your booking page interface."
        )
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

  # The ground a scheme card's dots sit on: the scheme's own background, so a
  # dark scheme reads dark.
  defp swatch_backing(%{colors: %{background: background}}), do: background
  defp swatch_backing(_scheme), do: nil

  # No `style` attribute at all without a backing, rather than the empty one
  # HEEx renders for `style={nil}`.
  defp backing_style(nil), do: []
  defp backing_style(background), do: [style: "background-color: #{background}"]

  defp primary_swatches(%{colors: colors}),
    do: [colors.primary, colors.secondary, colors.accent]

  # The presets' names (every theme's, Paper's palettes sharing Quill and
  # Rhythm's) and a seed's "Custom" all have `dashboard_appearance` entries.
  defp scheme_name(%{name: name}),
    do: Gettext.dgettext(TymeslotWeb.Gettext, "dashboard_appearance", name)
end
