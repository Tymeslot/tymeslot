defmodule TymeslotWeb.Dashboard.CalendarGrid.UpdateHandlers do
  @moduledoc "Update action handlers for CalendarGridComponent."

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [connected?: 1]

  alias Tymeslot.CalendarGrid
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

  @spec handle_event_delete_failed(map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def handle_event_delete_failed(assigns, socket) do
    socket =
      socket
      |> assign(Map.drop(assigns, [:action]))
      |> assign(:confirm_delete_event, nil)
      |> assign(:confirm_delete_linked_to_booking, false)
      |> assign(:deleting_event, false)

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

  @spec handle_video_link_updated(map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def handle_video_link_updated(%{event_id: event_id, video_link: video_link}, socket) do
    updated_events =
      Enum.map(socket.assigns.events, fn e ->
        if e.id == event_id, do: Map.put(e, :video_link, video_link), else: e
      end)

    selected = socket.assigns.selected_event

    socket =
      socket
      |> assign(:events, updated_events)
      |> then(fn s ->
        if selected && selected.id == event_id,
          do: assign(s, :selected_event, Map.put(selected, :video_link, video_link)),
          else: s
      end)

    {:ok, socket}
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
          |> Helpers.load_events()
          |> maybe_auto_refresh()
      end

    {:ok, socket}
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
