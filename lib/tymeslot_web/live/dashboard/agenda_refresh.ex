defmodule TymeslotWeb.Dashboard.AgendaRefresh do
  @moduledoc """
  Which dashboard sections show the day's agenda, and the timer that keeps
  it current while one is open.

  The agenda feeds the overview and the old calendar's Up-next strip. The
  new calendar surface hides the strip, so it neither queries the agenda nor
  keeps the timer.

  Unlike the calendar grid's query-free `:tick` (which only re-sends
  `current_time`), the `:agenda_tick` this schedules makes `DashboardLive`
  re-run `Agenda.day_agenda/2` from the database every 60s, to advance the
  now line, drop entries that have ended, and pick up bookings or calendar
  events created since the last load.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1]

  @tick_ms 60_000

  @doc "Whether the section the assigns describe shows the agenda."
  @spec shown?(map()) :: boolean()
  def shown?(%{live_action: :overview}), do: true
  def shown?(%{live_action: :calendar} = assigns), do: assigns[:calendar_redesign] != true
  def shown?(_assigns), do: false

  @doc """
  Keeps a single `:agenda_tick` timer alive only while a section that shows
  the agenda is open. Cancels any prior timer first so repeated visits never
  stack ticks.
  """
  @spec reschedule(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def reschedule(socket) do
    if ref = socket.assigns[:agenda_tick_ref], do: Process.cancel_timer(ref)

    if connected?(socket) and shown?(socket.assigns) do
      assign(socket, :agenda_tick_ref, Process.send_after(self(), :agenda_tick, @tick_ms))
    else
      assign(socket, :agenda_tick_ref, nil)
    end
  end
end
