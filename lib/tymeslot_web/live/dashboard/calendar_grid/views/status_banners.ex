defmodule TymeslotWeb.Dashboard.CalendarGrid.Views.StatusBanners do
  @moduledoc "Status banner function component (stale/syncing) for the calendar grid."

  use TymeslotWeb, :html

  # ---------- Status banners ----------

  attr :stale_integrations, :list, required: true
  attr :syncing, :boolean, required: true
  attr :sync_total, :integer, required: true
  attr :sync_completed, :integer, required: true
  attr :oldest_sync_at, :any
  attr :myself, :any, required: true

  @spec status_banners(map()) :: Phoenix.LiveView.Rendered.t()
  def status_banners(assigns) do
    ~H"""
    <div :if={@stale_integrations != [] and not @syncing} class="flex items-center gap-2 px-3 py-1.5 md:px-4 bg-amber-50 border-b border-amber-200 text-token-sm text-amber-700">
      <.icon name="hero-exclamation-triangle" class="w-4 h-4 shrink-0" />
      <span>
        <%= if @oldest_sync_at, do: "Calendar data may be outdated (last synced #{format_sync_age(@oldest_sync_at)}).", else: "Some calendars have never been synced." %>
      </span>
      <button
        phx-click="refresh"
        phx-target={@myself}
        class="underline hover:text-amber-900 font-medium"
      >Refresh now</button>
    </div>
    <div :if={@syncing} class="flex items-center gap-2 px-3 py-1.5 md:px-4 bg-turquoise-50 border-b border-turquoise-200 text-token-sm text-turquoise-700">
      <.icon name="hero-arrow-path" class="w-4 h-4 animate-spin shrink-0" />
      <span>Syncing calendars<%= if @sync_total > 1, do: " (#{@sync_completed}/#{@sync_total})", else: "" %>...</span>
    </div>
    """
  end

  defp format_sync_age(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end
end
