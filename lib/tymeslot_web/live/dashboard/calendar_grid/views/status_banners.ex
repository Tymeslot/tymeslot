defmodule TymeslotWeb.Dashboard.CalendarGrid.Views.StatusBanners do
  @moduledoc "Status banner function component (stale/syncing) for the calendar grid."

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  # ---------- Status banners ----------

  attr :stale_integrations, :list, required: true
  attr :syncing, :boolean, required: true
  attr :sync_total, :integer, required: true
  attr :sync_completed, :integer, required: true
  attr :oldest_sync_at, :any
  attr :myself, :any, required: true

  @spec status_banners(map()) :: Phoenix.LiveView.Rendered.t()
  def status_banners(assigns) do
    assigns =
      assign(
        assigns,
        :sync_progress,
        if(assigns.sync_total > 1,
          do: " (#{assigns.sync_completed}/#{assigns.sync_total})",
          else: ""
        )
      )

    ~H"""
    <div :if={@stale_integrations != [] and not @syncing} class="flex items-center gap-2 px-3 py-1.5 md:px-4 bg-amber-50 border-b border-amber-200 text-token-sm text-amber-700">
      <.icon name="hero-exclamation-triangle" class="w-4 h-4 shrink-0" />
      <span>
        <%= if @oldest_sync_at,
          do:
            dgettext("dashboard_calendar", "Calendar data may be outdated (last synced %{age}).",
              age: format_sync_age(@oldest_sync_at)
            ),
          else: dgettext("dashboard_calendar", "Some calendars have never been synced.") %>
      </span>
      <button
        phx-click="refresh"
        phx-target={@myself}
        class="underline hover:text-amber-900 font-medium"
      >{dgettext("dashboard_calendar", "Refresh now")}</button>
    </div>
    <div :if={@syncing} class="flex items-center gap-2 px-3 py-1.5 md:px-4 bg-turquoise-50 border-b border-turquoise-200 text-token-sm text-turquoise-700">
      <.icon name="hero-arrow-path" class="w-4 h-4 animate-spin shrink-0" />
      <span>{dgettext("dashboard_calendar", "Syncing calendars%{progress}...", progress: @sync_progress)}</span>
    </div>
    """
  end

  defp format_sync_age(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> dgettext("dashboard_calendar", "just now")
      diff < 3600 -> dgettext("dashboard_calendar", "%{minutes}m ago", minutes: div(diff, 60))
      diff < 86_400 -> dgettext("dashboard_calendar", "%{hours}h ago", hours: div(diff, 3600))
      true -> dgettext("dashboard_calendar", "%{days}d ago", days: div(diff, 86_400))
    end
  end
end
