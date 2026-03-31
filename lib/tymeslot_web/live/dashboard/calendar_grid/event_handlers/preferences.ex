defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Preferences do
  @moduledoc "Settings and preference event handlers for CalendarGridComponent."

  import Phoenix.Component, only: [assign: 3]

  alias Phoenix.LiveView
  alias Tymeslot.CalendarGrid
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers
  alias TymeslotWeb.Dashboard.CalendarGridComponent

  @allowed_preference_keys ~w(week_start_day time_format default_view show_week_numbers show_weekends)a

  @spec handle_toggle_settings(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_toggle_settings(_params, socket) do
    {:noreply,
     socket
     |> assign(:show_settings, !socket.assigns.show_settings)
     |> assign(:show_calendar_list, false)
     |> assign(:show_view_menu, false)}
  end

  @spec handle_close_settings(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_close_settings(_params, socket) do
    {:noreply, assign(socket, :show_settings, false)}
  end

  @spec handle_update_preference(map(), Phoenix.LiveView.Socket.t(), atom()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_preference(%{"option" => value}, socket, key)
      when key in @allowed_preference_keys do
    user_id = socket.assigns.current_user.id

    case CalendarGrid.save_preferences(user_id, %{key => value}) do
      {:ok, _preferences} ->
        prefs = %{socket.assigns.preferences | key => value}

        socket =
          socket
          |> assign(:preferences, prefs)
          |> Helpers.precompute_derived()

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, socket}
    end
  end

  def handle_update_preference(_params, socket, _key), do: {:noreply, socket}

  @spec handle_update_default_view(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_default_view(%{"option" => value}, socket)
      when value in ~w(day week month) do
    user_id = socket.assigns.current_user.id
    view_atom = String.to_existing_atom(value)
    CalendarGrid.save_preferences(user_id, %{default_view: value})

    prefs = %{socket.assigns.preferences | default_view: value}

    # Instant grid switch (no DB query, no flicker)
    socket =
      socket
      |> assign(:preferences, prefs)
      |> assign(:view, view_atom)
      |> Helpers.precompute_derived()

    # Deferred event reload for the new view's date range
    LiveView.send_update_after(
      CalendarGridComponent,
      %{id: "calendar", action: :reload_events},
      50
    )

    {:noreply, socket}
  end

  @spec handle_toggle_preference(map(), Phoenix.LiveView.Socket.t(), atom()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_toggle_preference(_params, socket, key)
      when key in @allowed_preference_keys do
    user_id = socket.assigns.current_user.id
    new_value = !Map.get(socket.assigns.preferences, key)

    case CalendarGrid.save_preferences(user_id, %{key => new_value}) do
      {:ok, _preferences} ->
        prefs = %{socket.assigns.preferences | key => new_value}

        socket =
          socket
          |> assign(:preferences, prefs)
          |> Helpers.precompute_derived()

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, socket}
    end
  end

  def handle_toggle_preference(_params, socket, _key), do: {:noreply, socket}
end
