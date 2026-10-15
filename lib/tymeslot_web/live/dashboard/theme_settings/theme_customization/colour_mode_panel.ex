defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.ColourModePanel do
  @moduledoc """
  The dashboard panel for an `Options.ColourMode` group: the booking page
  light, dark, or matching each visitor's device. It keeps no UI state, so
  the `Panel` defaults for `ui/3`, `handle_ui/5` and `telemetry/3` stand.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext
  use TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panel

  alias Tymeslot.ThemeCustomizations.Options.ColourMode
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panel

  @impl Panel
  def render(assigns) do
    assigns =
      assign(assigns, :mode, ColourMode.mode(assigns.customization.settings, assigns.group))

    ~H"""
    <.card
      title={dgettext("dashboard_appearance", "Colour Mode")}
      description={
        dgettext(
          "dashboard_appearance",
          "Show your booking page light or dark, or let it follow each visitor's device."
        )
      }
      data-testid="colour-mode-panel"
    >
      <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
        <button
          :for={mode <- ColourMode.modes()}
          type="button"
          class={[
            "flex flex-col items-center gap-3 p-5 rounded-token-2xl border-2 transition-all duration-300",
            if(@mode == mode,
              do: "bg-turquoise-50 border-turquoise-400 shadow-xl shadow-turquoise-500/10",
              else: "bg-white border-tymeslot-50 hover:border-turquoise-200 hover:shadow-lg"
            )
          ]}
          phx-click="theme:set_option"
          phx-value-option={@group.key}
          phx-value-field="mode"
          phx-value-choice={mode}
          phx-target={@myself}
          aria-pressed={to_string(@mode == mode)}
        >
          <.icon
            name={mode_icon(mode)}
            class={"w-6 h-6 #{if @mode == mode, do: "text-turquoise-600", else: "text-tymeslot-400"}"}
          />
          <span class={[
            "text-token-sm font-black uppercase tracking-widest",
            if(@mode == mode, do: "text-turquoise-700", else: "text-tymeslot-500")
          ]}>
            {label(mode)}
          </span>
        </button>
      </div>
    </.card>
    """
  end

  defp mode_icon("light"), do: "hero-sun"
  defp mode_icon("dark"), do: "hero-moon"
  defp mode_icon("auto"), do: "hero-computer-desktop"

  defp label("light"), do: dgettext("dashboard_appearance", "Light")
  defp label("dark"), do: dgettext("dashboard_appearance", "Dark")
  defp label("auto"), do: dgettext("dashboard_appearance", "Match device")
end
