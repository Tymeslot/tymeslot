defmodule TymeslotWeb.Dashboard.CalendarGrid.UpdateHandlers do
  @moduledoc "Update action handlers for CalendarGridComponent."

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [connected?: 1]

  alias Tymeslot.CalendarGrid
  alias TymeslotWeb.Dashboard.CalendarGrid.DesktopReminderFeed
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers

  @spec handle_revert_event(map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def handle_revert_event(%{original_event: original} = assigns, socket) do
    socket = assign(socket, Map.drop(assigns, [:action, :original_event]))

    reverted_events =
      Enum.map(socket.assigns.events, fn e ->
        if e.id == original.id, do: original, else: e
      end)

    selected = socket.assigns.selected_event

    socket =
      socket
      |> assign(:events, reverted_events)
      |> then(fn s ->
        if selected && selected.id == original.id,
          do: assign(s, :selected_event, original),
          else: s
      end)
      |> Helpers.precompute_derived()

    {:ok, socket}
  end

  @spec handle_refresh_events(map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def handle_refresh_events(assigns, socket) do
    was_syncing = socket.assigns.syncing

    socket =
      socket
      |> assign(Map.drop(assigns, [:action]))
      |> assign(:syncing, false)
      |> assign(:sync_total, 0)
      |> assign(:sync_completed, 0)
      |> Helpers.load_integrations()
      |> Helpers.load_events()

    if was_syncing, do: send(self(), :calendar_sync_flash)

    {:ok, socket}
  end

  @spec handle_reload_events(map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def handle_reload_events(assigns, socket) do
    socket =
      socket
      |> assign(Map.drop(assigns, [:action]))
      |> Helpers.load_events()

    {:ok, socket}
  end

  @spec handle_ad_hoc_meeting_created(map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def handle_ad_hoc_meeting_created(assigns, socket) do
    socket =
      socket
      |> assign(Map.drop(assigns, [:action]))
      |> assign(:creating_event, nil)
      |> assign(:saving_event, false)
      |> Helpers.load_events()

    {:ok, socket}
  end

  @spec handle_ad_hoc_meeting_failed(map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def handle_ad_hoc_meeting_failed(assigns, socket) do
    socket =
      socket
      |> assign(Map.drop(assigns, [:action]))
      |> assign(:saving_event, false)

    {:ok, socket}
  end

  @spec handle_event_created(map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def handle_event_created(assigns, socket) do
    socket =
      socket
      |> assign(Map.drop(assigns, [:action]))
      |> assign(:creating_event, nil)
      |> assign(:saving_event, false)
      |> Helpers.load_events()

    {:ok, socket}
  end

  @spec handle_event_create_failed(map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def handle_event_create_failed(assigns, socket) do
    socket =
      socket
      |> assign(Map.drop(assigns, [:action]))
      |> assign(:saving_event, false)

    {:ok, socket}
  end

  @spec handle_event_moved(map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def handle_event_moved(assigns, socket) do
    new_uid = assigns[:new_event_uid]
    new_integration_id = assigns[:new_event_integration_id]

    socket =
      socket
      |> assign(Map.drop(assigns, [:action, :new_event_uid, :new_event_integration_id]))
      |> Helpers.load_events()

    new_event =
      Enum.find(socket.assigns.events, fn e ->
        e.uid == new_uid and e.calendar_integration_id == new_integration_id
      end)

    {:ok, assign(socket, :selected_event, new_event)}
  end

  @spec handle_event_deleted(map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def handle_event_deleted(assigns, socket) do
    socket =
      socket
      |> assign(Map.drop(assigns, [:action]))
      |> assign(:confirm_delete_event, nil)
      |> assign(:confirm_delete_linked_to_booking, false)
      |> assign(:deleting_event, false)
      |> assign(:selected_event, nil)
      |> Helpers.load_events()

    {:ok, socket}
  end

  @doc """
  Resets the confirmation after a delete the provider would not take.

  Reloads the events on purpose, because a refused delete can still have
  changed what the grid should show. A delete queued for retry leaves the
  cached row marked `locally_deleted` with no timing, so the reload drops the
  event the moment the flash says the delete is queued rather than leaving it
  on screen until an unrelated reload. A failure that was not queued leaves
  the row untouched, so the event stays where it was.
  """
  @spec handle_event_delete_failed(map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def handle_event_delete_failed(assigns, socket) do
    socket =
      socket
      |> assign(Map.drop(assigns, [:action]))
      |> assign(:confirm_delete_event, nil)
      |> assign(:confirm_delete_linked_to_booking, false)
      |> assign(:deleting_event, false)
      |> Helpers.load_events()

    {:ok, socket}
  end

  @spec handle_events_updated(map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def handle_events_updated(assigns, socket) do
    socket =
      socket
      |> assign(Map.drop(assigns, [:action]))
      |> Helpers.load_events()

    {:ok, socket}
  end

  @spec handle_integration_synced(map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def handle_integration_synced(assigns, socket) do
    total = socket.assigns.sync_total
    completed = socket.assigns.sync_completed + 1

    socket =
      socket
      |> assign(Map.drop(assigns, [:action]))
      |> assign(:sync_completed, completed)

    socket =
      cond do
        # User-initiated sync completed: reload everything and show flash.
        total > 0 and completed >= total ->
          send(self(), :calendar_sync_flash)

          socket
          |> assign(:syncing, false)
          |> assign(:sync_total, 0)
          |> assign(:sync_completed, 0)
          |> Helpers.load_integrations()
          |> Helpers.load_events()

        # Background sync (sweep worker): silently refresh events only.
        total == 0 ->
          socket
          |> assign(:sync_completed, 0)
          |> Helpers.load_events()

        # User-initiated sync still in progress.
        true ->
          socket
      end

    {:ok, socket}
  end

  @doc """
  Applies a finished video-room change to the loaded events, then runs the
  same attendee-notification decision every other inline edit ends in.

  Only the three columns the change wrote are merged, rather than the updated
  event replacing what is on screen, so a sync that landed while the room was
  being provisioned is not rolled back. The description is one of them: the
  join link is written into it, and leaving it behind would show the previous
  link in the detail modal.
  """
  @spec handle_video_link_updated(map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def handle_video_link_updated(%{original_event: original, updated_event: updated}, socket) do
    video = Map.take(updated, [:video_link, :video_integration_id, :description])

    updated_events =
      Enum.map(socket.assigns.events, fn e ->
        if e.id == updated.id, do: Map.merge(e, video), else: e
      end)

    selected = socket.assigns.selected_event

    socket =
      socket
      |> assign(:events, updated_events)
      |> then(fn s ->
        if selected && selected.id == updated.id,
          do: assign(s, :selected_event, Map.merge(selected, video)),
          else: s
      end)

    {:ok,
     EditWorkflow.apply_notify_result(
       socket,
       original,
       updated,
       EditWorkflow.video_changed_message(updated.video_link)
     )}
  end

  @spec handle_initial(map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def handle_initial(assigns, socket) do
    socket = assign(socket, assigns)

    socket =
      cond do
        Map.get(socket.assigns, :_initialized) ->
          socket

        not connected?(socket) ->
          socket

        true ->
          Process.send_after(self(), :tick, 60_000)

          socket
          |> assign(:_initialized, true)
          |> Helpers.load_integrations()
          |> Helpers.assign_view_from_preferences()
          |> Helpers.assign_timezone()
          |> open_on_today()
          |> Helpers.load_events()
          |> maybe_auto_refresh()
      end

    {:ok, assign_desktop_reminder_feed(socket)}
  end

  defp open_on_today(socket),
    do: assign(socket, :date, Helpers.today(socket.assigns.user_timezone))

  # Recomputes the upcoming desktop-reminder feed. Runs on the initial connect
  # and again on every 60s `current_time` tick (which routes through this same
  # handler), so the browser always has a fresh window of fire times without a
  # dedicated server timer. When the preference is off we assign an empty feed
  # so the hook stays inert.
  defp assign_desktop_reminder_feed(socket) do
    prefs = socket.assigns[:preferences]

    if (connected?(socket) and prefs) && prefs.desktop_reminders_enabled do
      now = socket.assigns[:current_time] || DateTime.utc_now()
      timezone = socket.assigns[:user_timezone] || "Etc/UTC"
      time_format = Helpers.time_format(socket.assigns)

      integrations = Map.get(socket.assigns, :integrations, [])

      feed =
        socket
        |> visible_integration_ids()
        |> CalendarGrid.list_upcoming_events_with_reminders(now, integrations)
        |> DesktopReminderFeed.build(now, timezone, time_format)

      assign(socket, :desktop_reminders_feed, feed)
    else
      assign(socket, :desktop_reminders_feed, [])
    end
  end

  defp visible_integration_ids(socket) do
    hidden = socket.assigns[:hidden_integration_ids] || []

    socket.assigns
    |> Map.get(:integrations, [])
    |> Enum.map(& &1.id)
    |> Enum.reject(&(&1 in hidden))
  end

  defp maybe_auto_refresh(socket) do
    if socket.assigns.stale_integrations != [] do
      user_id = socket.assigns.current_user.id

      result = CalendarGrid.refresh_events(user_id)

      case result do
        {:ok, %{enqueued: 0}} ->
          socket

        {:ok, %{enqueued: enqueued, skipped: skipped}} ->
          Process.send_after(self(), :reset_calendar_sync, 30_000)

          socket
          |> assign(:syncing, true)
          |> assign(:sync_total, enqueued + skipped)
          |> assign(:sync_completed, skipped)
      end
    else
      socket
    end
  end
end
