defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.CalendarViewPanel do
  @moduledoc """
  The dashboard panel for an `Options.CalendarView` group: a month or a week. It keeps no UI state.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext
  use TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panel

  alias Tymeslot.ThemeCustomizations.Options.CalendarView
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panel

  @impl Panel
  def render(assigns) do
    assigns =
      assign(assigns, :choice, CalendarView.choice(assigns.customization.settings, assigns.group))

    ~H"""
    <div class="card-glass" data-testid="calendar-view-panel">
      <div class="mb-8">
        <h3 class="text-token-xl font-black text-tymeslot-900 tracking-tight">
          {dgettext("dashboard_appearance", "Calendar View")}
        </h3>
        <p class="text-token-sm text-tymeslot-500 font-bold mt-1">
          {dgettext(
            "dashboard_appearance",
            "Pick a day from a month, or see a whole week of free times at once."
          )}
        </p>
      </div>

      <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <button
          :for={view <- CalendarView.choices()}
          type="button"
          class={[
            "flex flex-col items-center gap-3 p-5 rounded-token-2xl border-2 transition-all duration-300",
            if(@choice == view,
              do: "bg-turquoise-50 border-turquoise-400 shadow-xl shadow-turquoise-500/10",
              else: "bg-white border-tymeslot-50 hover:border-turquoise-200 hover:shadow-lg"
            )
          ]}
          phx-click="theme:set_option"
          phx-value-option={@group.key}
          phx-value-field="calendar_view"
          phx-value-choice={view}
          phx-target={@myself}
          aria-pressed={to_string(@choice == view)}
        >
          <.icon
            name={view_icon(view)}
            class={"w-6 h-6 #{if @choice == view, do: "text-turquoise-600", else: "text-tymeslot-400"}"}
          />
          <span class={[
            "text-token-sm font-black uppercase tracking-widest",
            if(@choice == view, do: "text-turquoise-700", else: "text-tymeslot-500")
          ]}>
            {label(view)}
          </span>
        </button>
      </div>
    </div>
    """
  end

  defp view_icon("month"), do: "hero-calendar-days"
  defp view_icon("week"), do: "hero-view-columns"

  defp label("month"), do: dgettext("dashboard_appearance", "Month")
  defp label("week"), do: dgettext("dashboard_appearance", "Week")
end
