defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.AccentPanel do
  @moduledoc """
  The dashboard panel for an `Options.Accent` group: the group's accent
  presets, in its order, and a custom colour. "Custom" on a preset saves that
  preset's colour as the custom accent, which opens the colour widget; on a
  custom accent it only shows or hides the widget.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext
  use TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panel

  alias Tymeslot.ThemeCustomizations.Options.Accent
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panel

  import TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.CurrentIndicator,
    only: [current_indicator: 1]

  import TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Pickers.ColourPickerWidget,
    only: [colour_picker_widget: 1]

  @impl Panel
  def render(assigns) do
    choice = Accent.choice(assigns.customization.settings, assigns.group)

    assigns =
      assign(assigns,
        choice: choice,
        custom: Accent.custom?(choice),
        colour: Accent.colour(assigns.customization.settings, assigns.group),
        presets: Accent.presets(assigns.group)
      )

    ~H"""
    <.card
      title={dgettext("dashboard_appearance", "Accent Colour")}
      description={
        dgettext(
          "dashboard_appearance",
          "The colour of the buttons, links and highlights on your booking page."
        )
      }
      data-testid="accent-panel"
    >
      <:actions>
        <.current_indicator
          :if={@colour}
          swatches={[@colour]}
          label={current_label(@choice, @presets)}
          code={if @custom, do: String.upcase(@colour)}
          highlighted={@custom}
        />
        <button
          type="button"
          phx-click="theme:toggle_accent_picker"
          phx-value-option={@group.key}
          phx-target={@myself}
          aria-expanded={to_string(@accent_picker_open)}
          aria-controls="custom-accent-picker"
          class={[
            "flex items-center gap-2 px-3.5 py-2 rounded-token-xl border-2 text-token-2xs font-black uppercase tracking-widest transition-all duration-300",
            if(@accent_picker_open,
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
            class={"w-4 h-4 transition-transform duration-300 #{if @accent_picker_open, do: "rotate-180"}"}
          />
        </button>
      </:actions>

      <%!-- The param is named `choice` rather than `value`: see PalettePanel. --%>
      <div class="grid grid-cols-3 sm:grid-cols-5 lg:grid-cols-9 gap-3">
        <button
          :for={{id, preset} <- @presets}
          type="button"
          class={[
            "flex flex-col items-center gap-2 p-3 rounded-token-2xl border-2 transition-all duration-300",
            if(@choice == id,
              do: "bg-turquoise-50 border-turquoise-400 shadow-lg shadow-turquoise-500/10",
              else: "bg-white border-tymeslot-50 hover:border-turquoise-200 hover:shadow-lg"
            )
          ]}
          phx-click="theme:set_option"
          phx-value-option={@group.key}
          phx-value-field="preset"
          phx-value-choice={id}
          phx-target={@myself}
          aria-pressed={to_string(@choice == id)}
        >
          <span
            class="w-8 h-8 rounded-token-full shadow-sm border-2 border-white"
            style={"background-color: #{preset.color}"}
          ></span>
          <span class={[
            "text-token-2xs font-black uppercase tracking-widest",
            if(@choice == id, do: "text-turquoise-700", else: "text-tymeslot-500")
          ]}>
            {preset_name(preset)}
          </span>
        </button>
      </div>

      <div
        :if={@custom and @accent_picker_open}
        class="mt-6 animate-fade-in-up rounded-token-2xl border-2 border-tymeslot-50 bg-tymeslot-50/50 p-4"
      >
        <.colour_picker_widget
          id="custom-accent-picker"
          target={@myself}
          initial_hex={@colour}
          commit_event="theme:set_option"
          commit_params={%{option: @group.key, field: "custom"}}
        />
      </div>
    </.card>
    """
  end

  # The widget is open exactly while a custom colour is the accent, both on
  # load and after a save: choosing a preset closes it.
  @impl Panel
  def ui(group, customization, _ui),
    do: %{accent_picker_open: Accent.custom?(Accent.choice(customization.settings, group))}

  @impl Panel
  def handle_ui("theme:toggle_accent_picker", _params, group, ui, customization) do
    if Accent.custom?(Accent.choice(customization.settings, group)) do
      {:ui, %{ui | accent_picker_open: not ui.accent_picker_open}}
    else
      case Accent.colour(customization.settings, group) do
        nil -> :ignore
        colour -> {:set, "custom", colour}
      end
    end
  end

  def handle_ui(_event, _params, _group, _ui, _customization), do: :ignore

  defp current_label(choice, presets) do
    case List.keyfind(presets, choice, 0) do
      {_id, preset} -> preset_name(preset)
      nil -> dgettext("dashboard_appearance", "Custom")
    end
  end

  # Preset names are registered for extraction in `Presets.Accents` and
  # translated here, in the viewer's locale; a name with no entry (the brand)
  # comes back as it is.
  defp preset_name(%{name: name}),
    do: Gettext.dgettext(TymeslotWeb.Gettext, "dashboard_appearance", name)
end
