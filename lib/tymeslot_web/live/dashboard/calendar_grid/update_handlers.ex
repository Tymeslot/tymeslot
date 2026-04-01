defmodule TymeslotWeb.Dashboard.CalendarGrid.UpdateHandlers do
  @moduledoc "Update action handlers for CalendarGridComponent."

  import Phoenix.Component, only: [assign: 2, assign: 3]

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
    completed = socket.assigns.sync_completed + 1
    total = socket.assigns.sync_total

    socket =
      socket
      |> assign(Map.drop(assigns, [:action]))
      |> assign(:sync_completed, completed)

    socket =
      if completed >= total do
        send(self(), :calendar_sync_flash)

        socket
        |> assign(:syncing, false)
        |> assign(:sync_total, 0)
        |> assign(:sync_completed, 0)
        |> Helpers.load_integrations()
        |> Helpers.load_events()
      else
        socket
      end

    {:ok, socket}
  end

  @spec handle_initial(map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def handle_initial(assigns, socket) do
    socket = assign(socket, assigns)

    socket =
      if Map.get(socket.assigns, :_initialized) do
        socket
      else
        Process.send_after(self(), :tick, 60_000)

        socket
        |> assign(:_initialized, true)
        |> Helpers.load_integrations()
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
        {:ok, %{enqueued: enqueued, skipped: skipped}} ->
          Process.send_after(self(), :reset_calendar_sync, 30_000)

          socket
          |> assign(:syncing, true)
          |> assign(:sync_total, enqueued + skipped)
          |> assign(:sync_completed, skipped)

        _error ->
          socket
      end
    else
      socket
    end
  end
end
