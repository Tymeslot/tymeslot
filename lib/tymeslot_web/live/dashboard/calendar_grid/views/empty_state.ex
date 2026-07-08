defmodule TymeslotWeb.Dashboard.CalendarGrid.Views.EmptyState do
  @moduledoc "Empty-state banner shown when no calendars are connected."

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  @spec no_calendars_banner(map()) :: Phoenix.LiveView.Rendered.t()
  def no_calendars_banner(assigns) do
    hours = Enum.to_list(6..20)
    days = ~w(Mon Tue Wed Thu Fri Sat Sun)
    assigns = assign(assigns, hours: hours, days: days)

    ~H"""
    <div class="relative flex-1 min-h-0 overflow-hidden">
      <%!-- Blurred calendar grid background --%>
      <div class="absolute inset-0 select-none" aria-hidden="true">
        <div class="h-full flex flex-col blur-[1px] opacity-60">
          <%!-- Day headers --%>
          <div class="grid grid-cols-8 border-b border-tymeslot-200">
            <div class="py-3 px-2"></div>
            <div :for={day <- @days} class="py-3 px-2 text-center border-l border-tymeslot-200">
              <span class="text-token-xs font-bold text-tymeslot-300">{day}</span>
            </div>
          </div>
          <%!-- Time rows --%>
          <div class="flex-1 overflow-hidden">
            <div :for={hour <- @hours} class="grid grid-cols-8 border-b border-tymeslot-200">
              <div class="py-4 px-2 text-right">
                <span class="text-token-xs text-tymeslot-300/50">{rem(hour, 12) |> then(&if(&1 == 0, do: 12, else: &1))} {if(hour < 12, do: "AM", else: "PM")}</span>
              </div>
              <div :for={_day <- @days} class="py-4 border-l border-tymeslot-200"></div>
            </div>
          </div>
        </div>
        <%!-- Gradient fade overlay --%>
        <div class="absolute inset-0 bg-linear-to-b from-white/40 via-transparent to-white/50"></div>
      </div>
      <%!-- Centred content --%>
      <div class="absolute inset-0 flex flex-col items-center justify-center px-6">
        <div class="w-20 h-20 bg-white/90 backdrop-blur rounded-token-2xl flex items-center justify-center mb-6 shadow-sm border-2 border-dashed border-tymeslot-100">
          <.icon name="hero-calendar-days" class="w-10 h-10 text-tymeslot-300" />
        </div>
        <h2 class="text-token-xl font-bold text-tymeslot-800 mb-2">{dgettext("dashboard_calendar", "Nothing to see here")}</h2>
        <p class="text-token-base text-tymeslot-500 text-center max-w-md mb-8">
          {dgettext("dashboard_calendar", "Connect at least one calendar to see your events here.")}
        </p>
        <.link
          patch={~p"/dashboard/integrations?tab=calendars"}
          class="inline-flex items-center gap-2 px-6 py-3 bg-turquoise-600 hover:bg-turquoise-700 text-white font-bold rounded-token-xl transition-colors shadow-lg shadow-turquoise-500/20"
        >
          <.icon name="hero-plus" class="w-5 h-5" />
          {dgettext("dashboard_calendar", "Connect a calendar")}
        </.link>
      </div>
    </div>
    """
  end
end
