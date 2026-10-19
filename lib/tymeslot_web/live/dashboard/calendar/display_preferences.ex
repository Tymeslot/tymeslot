defmodule TymeslotWeb.Dashboard.Calendar.DisplayPreferences do
  @moduledoc """
  Saves the calendar surface's display choices (density and the folded
  night) and tells the `CalendarCanvas` hook to redraw with them. Its events
  arrive through `PowerEvents`.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CalendarGrid
  alias TymeslotWeb.Dashboard.Calendar.SurfaceData
  alias TymeslotWeb.Live.Shared.Flash

  @type socket :: Phoenix.LiveView.Socket.t()

  @spec handle(String.t(), map(), socket()) :: {:noreply, socket()}
  def handle("calendar:set_density", %{"option" => density}, socket),
    do: {:noreply, set_density(socket, density)}

  def handle("calendar:toggle_fold_night", _params, socket),
    do: {:noreply, toggle_fold_night(socket)}

  def handle(_event, _params, socket), do: {:noreply, socket}

  @doc "Saves `density` when it is one the grid can draw."
  @spec set_density(socket(), term()) :: socket()
  def set_density(socket, density) do
    if density in CalendarGrid.densities(),
      do: save(socket, :density, density, :settings),
      else: socket
  end

  @doc "Flips whether the hours before 07:00 fold into one strip."
  @spec toggle_fold_night(socket()) :: socket()
  def toggle_fold_night(socket),
    do: save(socket, :fold_night, !socket.assigns.preferences.fold_night, :settings)

  @doc """
  Saves one display preference and applies it: `:settings` redraws the grid
  from a settings push. A failed save keeps what was shown and says so.
  """
  @spec save(socket(), atom(), term(), :settings) :: socket()
  def save(socket, key, value, :settings) do
    case CalendarGrid.save_preferences(socket.assigns.current_user.id, %{key => value}) do
      {:ok, _preferences} ->
        socket |> SurfaceData.put_preference(key, value) |> SurfaceData.push_settings()

      {:error, _changeset} ->
        Flash.put_flash(
          socket,
          :error,
          dgettext("dashboard_calendar", "Couldn't save that change. Please try again.")
        )
    end
  end
end
