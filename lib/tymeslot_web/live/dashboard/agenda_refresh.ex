defmodule TymeslotWeb.Dashboard.AgendaRefresh do
  @moduledoc """
  Which dashboard sections show the day's agenda, and the timer that keeps
  it current while one is open.

  The agenda feeds the overview and the Up next strip above the calendar.

  The `:agenda_tick` this schedules makes `DashboardLive` re-run
  `Agenda.day_agenda/2` from the database every 60s, to advance the now line,
  drop entries that have ended, and pick up bookings or calendar events
  created since the last load.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [connected?: 1]

  alias Tymeslot.Dashboard.DashboardContext
  alias Tymeslot.Profiles

  @tick_ms 60_000

  @doc "Whether the section the assigns describe shows the agenda."
  @spec shown?(map()) :: boolean()
  def shown?(%{live_action: :overview}), do: true
  def shown?(%{live_action: :calendar}), do: true
  def shown?(_assigns), do: false

  @doc """
  Loads the data the current section shows: the day's agenda on the
  overview and on the calendar, nothing elsewhere.
  """
  @spec load(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def load(socket) do
    if user = socket.assigns[:current_user] do
      timezone = Profiles.timezone(socket.assigns[:profile])
      action = socket.assigns[:live_action]
      assign(socket, DashboardContext.get_dashboard_data_for_action(user, timezone, action))
    else
      socket
    end
  end

  @doc """
  Rebuilds the agenda when the current section shows it (`shown?/1`), on a
  tick or after a calendar change; a stale timer that fires after the user
  has navigated elsewhere is a no-op.
  """
  @spec refresh(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh(socket), do: if(shown?(socket.assigns), do: load(socket), else: socket)

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
