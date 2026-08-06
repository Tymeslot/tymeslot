defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Preferences do
  @moduledoc "Settings and preference event handlers for CalendarGridComponent."

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Phoenix.LiveView
  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.Appearance
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers.DataLoading
  alias TymeslotWeb.Dashboard.CalendarGridComponent
  alias TymeslotWeb.Live.Shared.Flash

  @allowed_preference_keys ~w(week_start_day time_format default_view show_week_numbers show_weekends desktop_reminders_enabled)a

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
        notify_parent(key, value)

        socket =
          socket
          |> assign(:preferences, prefs)
          |> Helpers.precompute_derived()

        {:noreply, socket}

      {:error, _changeset} ->
        send(
          self(),
          {:flash, {:error, dgettext("dashboard_calendar_events", "Failed to save preference")}}
        )

        {:noreply, socket}
    end
  end

  def handle_update_preference(_params, socket, _key), do: {:noreply, socket}

  @doc """
  Sets one calendar's colour, or clears it back to the integration's.

  The swatch component pushes the sentinel `"default"` from its clearing pill,
  which stores `nil` and restores inheritance rather than writing a colour that
  merely looks like the integration's.
  """
  @spec handle_set_calendar_colour(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_set_calendar_colour(
        %{"integration_id" => id_str, "calendar_id" => calendar_id, "colour" => colour},
        socket
      )
      when is_binary(calendar_id) and calendar_id != "" do
    user_id = socket.assigns.current_user.id
    stored = if colour == "default", do: nil, else: colour

    with :ok <- RateLimiter.check_integration_appearance_rate_limit(user_id),
         {:ok, integration_id} <- Shared.parse_int(id_str),
         {:ok, _appearance} <-
           Appearance.set_colour(user_id, integration_id, calendar_id, stored) do
      {:noreply,
       socket
       |> DataLoading.assign_calendar_appearances(user_id)
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

  def handle_set_calendar_colour(_params, socket), do: {:noreply, socket}

  # `time_format` is the one preference the dashboard mirrors outside this
  # component: `DashboardInitHook` resolves it once into `@time_format`, which
  # the overview, the agenda modal and the availability grid all render from.
  # Without this the calendar's own toggle would leave every other surface, and
  # the profile toggle that writes the same column, showing the old clock until
  # the next full page load.
  defp notify_parent(:time_format, value), do: send(self(), {:time_format_updated, value})
  defp notify_parent(_key, _value), do: :ok

  @spec handle_update_default_view(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_default_view(%{"option" => value}, socket)
      when value in ~w(day week month) do
    user_id = socket.assigns.current_user.id
    view_atom = String.to_existing_atom(value)

    case CalendarGrid.save_preferences(user_id, %{default_view: value}) do
      {:ok, _preferences} ->
        :ok

      {:error, _changeset} ->
        send(
          self(),
          {:flash, {:error, dgettext("dashboard_calendar_events", "Failed to save preference")}}
        )
    end

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
        send(
          self(),
          {:flash, {:error, dgettext("dashboard_calendar_events", "Failed to save preference")}}
        )

        {:noreply, socket}
    end
  end

  def handle_toggle_preference(_params, socket, _key), do: {:noreply, socket}
end
