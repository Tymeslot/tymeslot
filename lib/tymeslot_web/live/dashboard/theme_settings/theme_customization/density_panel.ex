defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.DensityPanel do
  @moduledoc """
  The dashboard panel for an `Options.Density` group: comfortable or compact
  spacing. It keeps no UI state.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext
  use TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panel

  alias Tymeslot.ThemeCustomizations.Options.Density
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panel

  @impl Panel
  def render(assigns) do
    assigns =
      assign(assigns, :choice, Density.choice(assigns.customization.settings, assigns.group))

    ~H"""
    <.card
      title={dgettext("dashboard_appearance", "Spacing")}
      description={
        dgettext(
          "dashboard_appearance",
          "How much room your booking page leaves around its content."
        )
      }
      data-testid="density-panel"
    >
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <button
          :for={density <- Density.choices()}
          type="button"
          class={[
            "flex flex-col items-center gap-3 p-5 rounded-token-2xl border-2 transition-all duration-300",
            if(@choice == density,
              do: "bg-turquoise-50 border-turquoise-400 shadow-xl shadow-turquoise-500/10",
              else: "bg-white border-tymeslot-50 hover:border-turquoise-200 hover:shadow-lg"
            )
          ]}
          phx-click="theme:set_option"
          phx-value-option={@group.key}
          phx-value-field="density"
          phx-value-choice={density}
          phx-target={@myself}
          aria-pressed={to_string(@choice == density)}
        >
          <.icon
            name={density_icon(density)}
            class={"w-6 h-6 #{if @choice == density, do: "text-turquoise-600", else: "text-tymeslot-400"}"}
          />
          <span class={[
            "text-token-sm font-black uppercase tracking-widest",
            if(@choice == density, do: "text-turquoise-700", else: "text-tymeslot-500")
          ]}>
            {label(density)}
          </span>
        </button>
      </div>
    </.card>
    """
  end

  defp density_icon("comfortable"), do: "hero-bars-3"
  defp density_icon("compact"), do: "hero-bars-4"

  defp label("comfortable"), do: dgettext("dashboard_appearance", "Comfortable")
  defp label("compact"), do: dgettext("dashboard_appearance", "Compact")
end
