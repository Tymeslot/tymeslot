defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Navigation do
  @moduledoc "Navigation event handlers for CalendarGridComponent."

  import Phoenix.Component, only: [assign: 3]

  require Logger

  alias Tymeslot.CalendarGrid
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.MiniMonth
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
  def handle_set_view(%{"view" => view}, socket)
      when view in ~w(day three_day week month agenda) do
    view_atom = String.to_existing_atom(view)

    # Only persist "real" view choices. `:three_day` is a responsive view that
    # should not override the user's stored preference — otherwise a narrow
    # viewport would permanently demote their week/month choice.
    if view in ~w(day week month agenda) do
      user_id = socket.assigns.current_user.id

      case CalendarGrid.save_preferences(user_id, %{default_view: view}) do
        {:ok, _preferences} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to save view preference", error: inspect(reason))
      end
    end

    socket =
      socket
      |> assign(:view, view_atom)
      |> assign(:show_view_menu, false)
      |> Helpers.load_events()

    {:noreply, socket}
  end

  def handle_set_view(_params, socket), do: {:noreply, socket}

  @doc "Switches the agenda view's lens between all entries and bookings only."
  @spec handle_set_agenda_lens(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_set_agenda_lens(%{"lens" => lens}, socket) when lens in ~w(all bookings) do
    {:noreply, assign(socket, :agenda_lens, String.to_existing_atom(lens))}
  end

  def handle_set_agenda_lens(_params, socket), do: {:noreply, socket}

  @spec handle_navigate_to_day(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_navigate_to_day(%{"date" => date_str}, socket) do
    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        socket =
          socket
          |> assign(:view, :day)
          |> assign(:date, date)
          |> MiniMonth.close()
          |> Helpers.load_events()

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  @spec handle_set_mobile_view(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_set_mobile_view(_params, socket),
    do: handle_set_responsive_view(%{"viewport" => "mobile"}, socket)

  @spec handle_set_responsive_view(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_set_responsive_view(%{"viewport" => viewport}, socket) do
    # Responsive demotion: a week-view on a narrow screen is illegible.
    # Mobile (<640px) → day view; tablet (<1024px) → 3-day view.
    # We only demote; we never upgrade the user's view choice.
    # We also do not persist the demoted view — `handle_set_view/2` gates
    # persistence to genuine user selections.
    target =
      case {viewport, socket.assigns.view} do
        {"mobile", :week} -> :day
        {"mobile", :three_day} -> :day
        {"mobile", :month} -> :month
        {"tablet", :week} -> :three_day
        _other -> socket.assigns.view
      end

    if target == socket.assigns.view do
      {:noreply, socket}
    else
      socket = socket |> assign(:view, target) |> Helpers.load_events()
      {:noreply, socket}
    end
  end

  def handle_set_responsive_view(_params, socket), do: {:noreply, socket}

  @spec handle_navigate_swipe(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_navigate_swipe(%{"direction" => direction}, socket) do
    delta =
      case direction do
        "next" -> 1
        "prev" -> -1
        _other -> 0
      end

    if delta == 0 do
      {:noreply, socket}
    else
      navigate_period(socket, delta)
    end
  end

  defp navigate_period(socket, direction) do
    new_date =
      case socket.assigns.view do
        :month -> Helpers.navigate_month(socket.assigns.date, direction)
        :agenda -> Date.add(socket.assigns.date, 30 * direction)
        :week -> Date.add(socket.assigns.date, 7 * direction)
        :three_day -> Date.add(socket.assigns.date, 3 * direction)
        :day -> Date.add(socket.assigns.date, direction)
      end

    socket = socket |> assign(:date, new_date) |> Helpers.load_events()
    {:noreply, socket}
  end
end
