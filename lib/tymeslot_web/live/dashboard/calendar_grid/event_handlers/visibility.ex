defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Visibility do
  @moduledoc "Calendar visibility and refresh event handlers for CalendarGridComponent."

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.Appearance
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

  @spec handle_close_calendar_list(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_close_calendar_list(_params, socket) do
    {:noreply, assign(socket, :show_calendar_list, false)}
  end

  @spec handle_close_view_menu(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_close_view_menu(_params, socket) do
    {:noreply, assign(socket, :show_view_menu, false)}
  end

  @spec handle_toggle_integration_visibility(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_toggle_integration_visibility(%{"integration-id" => id_str}, socket) do
    case Shared.parse_int(id_str) do
      {:ok, integration_id} -> handle_toggle_integration(socket, integration_id)
      :error -> {:noreply, socket}
    end
  end

  @doc """
  Shows or hides one calendar inside an integration.

  Rate limited on its own loose budget rather than the appearance one: this is a
  view control clicked while reading the week, not a settings change, so the
  limit sits where no hand-driven session reaches it.
  """
  @spec handle_toggle_calendar_visibility(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_toggle_calendar_visibility(
        %{"integration-id" => id_str, "calendar-id" => calendar_id},
        socket
      )
      when is_binary(calendar_id) and calendar_id != "" do
    case Shared.parse_int(id_str) do
      {:ok, integration_id} -> toggle_calendar(socket, integration_id, calendar_id)
      :error -> {:noreply, socket}
    end
  end

  def handle_toggle_calendar_visibility(_params, socket), do: {:noreply, socket}

  defp toggle_calendar(socket, integration_id, calendar_id) do
    user_id = socket.assigns.current_user.id
    key = {integration_id, calendar_id}
    hide? = not MapSet.member?(socket.assigns.hidden_calendar_keys, key)

    with :ok <- RateLimiter.check_calendar_visibility_rate_limit(user_id),
         {:ok, _appearance} <- Appearance.set_hidden(user_id, integration_id, calendar_id, hide?) do
      keys =
        if hide?,
          do: MapSet.put(socket.assigns.hidden_calendar_keys, key),
          else: MapSet.delete(socket.assigns.hidden_calendar_keys, key)

      {:noreply,
       socket
       |> assign(:hidden_calendar_keys, keys)
       |> Helpers.precompute_derived()}
    else
      {:error, :rate_limited, message} ->
        {:noreply, Flash.put_flash(socket, :warning, message)}

      _other ->
        {:noreply,
         Flash.put_flash(
           socket,
           :error,
           dgettext("dashboard_calendar_events", "Failed to save preference")
         )}
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
        {:noreply,
         Flash.put_flash(
           socket,
           :warning,
           dgettext("dashboard_calendar_events", "Too many refreshes. Please wait a moment.")
         )}
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
          Flash.put_flash(
            socket,
            :error,
            dgettext("dashboard_calendar_events", "Failed to save preference")
          )
      end

    {:noreply, socket}
  end

  defp do_refresh(socket, user_id) do
    case CalendarGrid.refresh_events(user_id) do
      {:ok, result} ->
        socket = Helpers.load_events(socket)

        # `load_events/1` reloads the grid's own mirror set, but the Up-next
        # strip and the overview agenda run their own query in the parent and
        # would keep serving the answer from before this refresh. That is the
        # moment it matters most: a refresh is what discovers a placeholder a
        # sync has just written, so the strip would advertise the organiser's
        # own mirror beside the source it mirrors.
        send(self(), :rebuild_agenda)

        cond do
          result.errors != [] ->
            error_count = length(result.errors)

            Flash.put_flash(
              socket,
              :warning,
              dngettext(
                "dashboard_calendar_events",
                "Refresh failed for %{count} integration",
                "Refresh failed for %{count} integrations",
                error_count,
                count: error_count
              )
            )

          result.enqueued == 0 and result.skipped == 0 ->
            Flash.put_flash(
              socket,
              :info,
              dgettext("dashboard_calendar_events", "No calendars to sync")
            )

          result.enqueued == 0 ->
            Flash.put_flash(
              socket,
              :info,
              dgettext("dashboard_calendar_events", "Calendars refreshed")
            )

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
