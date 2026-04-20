defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Visibility do
  @moduledoc "Calendar visibility and refresh event handlers for CalendarGridComponent."

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers
  alias TymeslotWeb.Live.Shared.Flash

  @spec handle_toggle_calendar_list(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_toggle_calendar_list(_params, socket) do
    {:noreply,
     socket
     |> assign(:show_calendar_list, !socket.assigns.show_calendar_list)
     |> assign(:show_view_menu, false)}
  end

  @spec handle_toggle_view_menu(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_toggle_view_menu(_params, socket) do
    {:noreply,
     socket
     |> assign(:show_view_menu, !socket.assigns.show_view_menu)
     |> assign(:show_calendar_list, false)}
  end

  @spec handle_toggle_integration_visibility(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_toggle_integration_visibility(%{"integration-id" => id_str}, socket) do
    case Shared.parse_int(id_str) do
      {:ok, integration_id} -> handle_toggle_integration(socket, integration_id)
      :error -> {:noreply, socket}
    end
  end

  @spec handle_refresh(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_refresh(_params, socket) do
    user_id = socket.assigns.current_user.id

    case RateLimiter.check_calendar_refresh_rate_limit(user_id) do
      :ok ->
        {:noreply, do_refresh(socket, user_id)}

      {:error, :rate_limited, _message} ->
        {:noreply, Flash.put_flash(socket, :warning, "Too many refreshes. Please wait a moment.")}
    end
  end

  defp handle_toggle_integration(socket, integration_id) do
    user_id = socket.assigns.current_user.id
    current_hidden = socket.assigns.hidden_integration_ids

    new_hidden =
      if integration_id in current_hidden do
        List.delete(current_hidden, integration_id)
      else
        [integration_id | current_hidden]
      end

    socket =
      case CalendarGrid.save_preferences(user_id, %{hidden_integration_ids: new_hidden}) do
        {:ok, _preferences} ->
          socket
          |> assign(:hidden_integration_ids, new_hidden)
          |> Helpers.precompute_derived()

        {:error, _changeset} ->
          Flash.put_flash(socket, :error, "Failed to save preference")
      end

    {:noreply, socket}
  end

  defp do_refresh(socket, user_id) do
    case CalendarGrid.refresh_events(user_id) do
      {:ok, result} ->
        socket =
          socket
          |> Helpers.load_events()
          |> push_event("calendar:scroll-to-current", %{})

        cond do
          result.errors != [] ->
            Flash.put_flash(
              socket,
              :warning,
              "Refresh failed for #{length(result.errors)} integration(s)"
            )

          result.enqueued == 0 and result.skipped == 0 ->
            Flash.put_flash(socket, :info, "No calendars to sync")

          result.enqueued == 0 ->
            Flash.put_flash(socket, :info, "Calendars refreshed")

          true ->
            # Schedule fallback reset in case workers complete without broadcasting
            Process.send_after(self(), :reset_calendar_sync, 30_000)

            socket
            |> assign(:syncing, true)
            |> assign(:sync_total, result.enqueued + result.skipped)
            |> assign(:sync_completed, result.skipped)
        end
    end
  end
end
