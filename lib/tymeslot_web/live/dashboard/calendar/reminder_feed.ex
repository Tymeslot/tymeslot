defmodule TymeslotWeb.Dashboard.Calendar.ReminderFeed do
  @moduledoc """
  The desktop-notification feed for the calendar: for the next eight
  days, the timed events that carry a reminder, as the entries the
  `DesktopReminders` hook fires (`DesktopReminderFeed.build/4`).

  It follows what the surface shows: the hidden accounts and the hidden
  calendar keys in the assigns, which hold the effective visibility (an
  active calendar set included).

  The surface gets no clock tick (see `CalendarEventHandlers`), so the feed
  refreshes itself: `schedule/1` asks for a `:reminder_tick` in 60 seconds,
  tagged with a fresh ref kept in `reminder_ref`, and `tick/2` acts only on
  that ref, so however often the loop is restarted, one loop lives. Nothing
  is scheduled while the preference is off or the socket is not connected.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, send_update_after: 3]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.EventWindow
  alias Tymeslot.Clock
  alias TymeslotWeb.Dashboard.Calendar.CalendarSurface
  alias TymeslotWeb.Dashboard.DesktopReminderFeed

  @tick_ms 60_000

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc """
  Rebuilds the feed; empty while the preference is off or the socket is not
  connected. Starts the loop when the preference is on and none is live (the
  preference may have been switched on elsewhere), and drops the ref when it
  is off, so an in-flight tick goes stale. A live loop is left alone.
  """
  @spec assign_feed(socket()) :: socket()
  def assign_feed(socket) do
    socket = rebuild(socket)

    cond do
      not live?(socket) -> assign(socket, :reminder_ref, nil)
      socket.assigns.reminder_ref == nil -> schedule(socket)
      true -> socket
    end
  end

  @doc "Rebuilds the feed and restarts its loop (the first load, the switch, a live tick)."
  @spec refresh(socket()) :: socket()
  def refresh(socket), do: socket |> rebuild() |> schedule()

  defp rebuild(socket) do
    if live?(socket),
      do: assign(socket, :reminder_feed, build(socket.assigns)),
      else: assign(socket, :reminder_feed, [])
  end

  @doc "Asks for the next tick under a fresh ref; while off, forgets the ref instead."
  @spec schedule(socket()) :: socket()
  def schedule(socket) do
    if live?(socket) do
      ref = make_ref()

      send_update_after(
        CalendarSurface,
        [id: socket.assigns.id, action: :reminder_tick, ref: ref],
        @tick_ms
      )

      assign(socket, :reminder_ref, ref)
    else
      assign(socket, :reminder_ref, nil)
    end
  end

  @doc "A tick: refreshes when `ref` is the live loop's, otherwise changes nothing."
  @spec tick(socket(), reference()) :: socket()
  def tick(%{assigns: %{reminder_ref: ref}} = socket, ref) when is_reference(ref),
    do: refresh(socket)

  def tick(socket, _stale_ref), do: socket

  defp live?(socket),
    do: socket.assigns.preferences.desktop_reminders_enabled == true and connected?(socket)

  defp build(assigns) do
    %{
      integrations: integrations,
      hidden_integration_ids: hidden_ids,
      hidden_calendar_keys: hidden_keys
    } = assigns

    now = Clock.utc_now()

    integrations
    |> Enum.map(& &1.id)
    |> Enum.reject(&(&1 in hidden_ids))
    |> CalendarGrid.list_upcoming_events_with_reminders(now, integrations)
    |> EventWindow.reject_hidden([], hidden_keys)
    |> DesktopReminderFeed.build(now, assigns.timezone, assigns.time_format)
  end
end
