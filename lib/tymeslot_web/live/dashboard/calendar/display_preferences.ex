defmodule TymeslotWeb.Dashboard.Calendar.DisplayPreferences do
  @moduledoc """
  Saves the calendar surface's display options and redraws with them.
  `PowerEvents` routes each option's event here. What a change needs
  depends on what it touches:

    * density, the folded night, week numbers and desktop notifications
      only change how the hook draws, so the settings are pushed again
      (`:settings`); desktop notifications are only switched off here, as
      switching them on waits for the browser (`DesktopPermission`);
    * the week start and weekends change the days and the loaded window, so
      the window is reloaded and pushed with a cache reset (`:window`);
    * the clock is also mirrored by `DashboardLive` for the rest of the
      dashboard (and handed back to the surface on every render), so the
      parent is told, and an open preview is rebuilt in it.

  Every handler parses its params again and ignores what it does not know.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Locales.WeekStart
  alias Tymeslot.Utils.DateTimeUtils.TimeFormat
  alias TymeslotWeb.Components.Shared.PickerPreferences
  alias TymeslotWeb.Dashboard.Calendar.ReminderFeed
  alias TymeslotWeb.Dashboard.Calendar.SurfaceData
  alias TymeslotWeb.Live.Shared.Flash

  @week_starts ~w(monday sunday)

  @type socket :: Phoenix.LiveView.Socket.t()
  @type effect :: :settings | :window

  @doc "Answers the display options' events (see `PowerEvents`)."
  @spec handle(String.t(), map(), socket()) :: {:noreply, socket()}
  def handle("calendar:set_density", %{"option" => density}, socket) do
    if density in CalendarGrid.densities(),
      do: {:noreply, save(socket, :density, density, :settings)},
      else: {:noreply, socket}
  end

  def handle("calendar:toggle_fold_night", _params, socket),
    do: {:noreply, toggle(socket, :fold_night, :settings)}

  def handle("calendar:toggle_weekends", _params, socket),
    do: {:noreply, toggle(socket, :show_weekends, :window)}

  def handle("calendar:toggle_week_numbers", _params, socket),
    do: {:noreply, toggle(socket, :show_week_numbers, :settings)}

  # The plain toggle only turns desktop notifications off. Turning them on
  # needs the browser's permission, which only `DesktopPermission` hears
  # about, so a click that reaches here while they are off (the permission
  # hook not loaded yet, or a stale client) changes nothing.
  def handle(
        "calendar:toggle_desktop_reminders",
        _params,
        %{assigns: %{preferences: %{desktop_reminders_enabled: true}}} = socket
      ),
      do:
        {:noreply,
         socket |> save(:desktop_reminders_enabled, false, :settings) |> ReminderFeed.refresh()}

  def handle("calendar:set_week_start", %{"option" => week_start}, socket)
      when week_start in @week_starts do
    if week_start == socket.assigns.preferences.week_start_day,
      do: {:noreply, socket},
      else:
        {:noreply, socket |> save(:week_start_day, week_start, :window) |> picker_week_start()}
  end

  def handle("calendar:set_time_format", %{"option" => format}, socket) do
    if TimeFormat.valid?(format) and format != socket.assigns.time_format,
      do: {:noreply, set_time_format(socket, format)},
      else: {:noreply, socket}
  end

  def handle(_event, _params, socket), do: {:noreply, socket}

  @doc """
  Saves one preference and redraws: `:settings` pushes the display settings
  again, `:window` reloads the window and pushes it with a cache reset.
  A failed save leaves everything as it was and says so.
  """
  @spec save(socket(), atom(), term(), effect()) :: socket()
  def save(socket, key, value, effect) do
    case CalendarGrid.save_preferences(socket.assigns.current_user.id, %{key => value}) do
      {:ok, _preferences} ->
        socket |> SurfaceData.put_preference(key, value) |> redraw(effect)

      {:error, _changeset} ->
        failed(socket)
    end
  end

  # The surface renders in the dashboard's process, so the date pickers' week
  # start follows the saved one from here (`PickerPreferences`).
  defp picker_week_start(socket) do
    PickerPreferences.put_week_start(WeekStart.parse(socket.assigns.preferences.week_start_day))
    socket
  end

  defp toggle(socket, key, effect),
    do: save(socket, key, !Map.fetch!(socket.assigns.preferences, key), effect)

  defp redraw(socket, :settings), do: SurfaceData.push_settings(socket)
  defp redraw(socket, :window), do: SurfaceData.reload(socket, :events)

  # The clock: saved, mirrored by the parent (whose next render hands the
  # surface the same value), and applied here at once, an open preview
  # included (`refilter/1` rebuilds it from the assigns).
  defp set_time_format(socket, format) do
    case CalendarGrid.save_preferences(socket.assigns.current_user.id, %{time_format: format}) do
      {:ok, _preferences} ->
        send(self(), {:time_format_updated, format})

        socket
        |> SurfaceData.put_preference(:time_format, format)
        |> assign(:time_format, format)
        |> SurfaceData.refilter()
        |> SurfaceData.push_settings()
        |> ReminderFeed.assign_feed()

      {:error, _changeset} ->
        failed(socket)
    end
  end

  defp failed(socket),
    do:
      Flash.put_flash(
        socket,
        :error,
        dgettext("dashboard_calendar", "Couldn't save that change. Please try again.")
      )
end
