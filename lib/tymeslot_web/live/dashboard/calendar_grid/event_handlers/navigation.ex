defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Navigation do
  @moduledoc "Navigation event handlers for CalendarGridComponent."

  import Phoenix.Component, only: [assign: 3]

  require Logger

  alias Tymeslot.CalendarGrid
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers

  @spec handle_prev_period(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_prev_period(_params, socket), do: navigate_period(socket, -1)

  @spec handle_next_period(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_next_period(_params, socket), do: navigate_period(socket, 1)

  @spec handle_today(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_today(_params, socket) do
    today =
      DateTime.utc_now()
      |> DateTime.shift_zone!(socket.assigns.user_timezone)
      |> DateTime.to_date()

    socket =
      socket
      |> assign(:date, today)
      |> Helpers.load_events()

    {:noreply, socket}
  end

  @spec handle_set_view(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_set_view(%{"view" => view}, socket) when view in ~w(day week month) do
    view_atom = String.to_existing_atom(view)
    user_id = socket.assigns.current_user.id

    case CalendarGrid.save_preferences(user_id, %{default_view: view}) do
      {:ok, _preferences} -> :ok
      {:error, reason} -> Logger.warning("Failed to save view preference", error: inspect(reason))
    end

    socket =
      socket
      |> assign(:view, view_atom)
      |> assign(:show_view_menu, false)
      |> Helpers.load_events()

    {:noreply, socket}
  end

  def handle_set_view(_params, socket), do: {:noreply, socket}

  @spec handle_navigate_to_day(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_navigate_to_day(%{"date" => date_str}, socket) do
    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        socket = socket |> assign(:view, :day) |> assign(:date, date) |> Helpers.load_events()
        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  @spec handle_set_mobile_view(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_set_mobile_view(_params, socket) do
    if socket.assigns.view == :week do
      socket = socket |> assign(:view, :day) |> Helpers.load_events()
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @spec handle_navigate_swipe(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_navigate_swipe(%{"direction" => direction}, socket) do
    new_date =
      case direction do
        "next" -> Date.add(socket.assigns.date, 1)
        "prev" -> Date.add(socket.assigns.date, -1)
        _other -> socket.assigns.date
      end

    socket = socket |> assign(:date, new_date) |> Helpers.load_events()
    {:noreply, socket}
  end

  defp navigate_period(socket, direction) do
    new_date =
      case socket.assigns.view do
        :month -> Helpers.navigate_month(socket.assigns.date, direction)
        :week -> Date.add(socket.assigns.date, 7 * direction)
        :day -> Date.add(socket.assigns.date, direction)
      end

    socket = socket |> assign(:date, new_date) |> Helpers.load_events()
    {:noreply, socket}
  end
end
