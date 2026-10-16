defmodule TymeslotWeb.Dashboard.Calendar.DisplayPreferences do
  @moduledoc """
  Saves the calendar surface's display choices (density and the folded
  night) and tells the `CalendarCanvas` hook to redraw with them.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CalendarGrid
  alias TymeslotWeb.Dashboard.Calendar.SurfaceData
  alias TymeslotWeb.Live.Shared.Flash

  @doc "Saves `density` when it is one the grid can draw."
  @spec set_density(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def set_density(socket, density) do
    if density in CalendarGrid.densities(), do: save(socket, :density, density), else: socket
  end

  @doc "Flips whether the hours before 07:00 fold into one strip."
  @spec toggle_fold_night(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def toggle_fold_night(socket),
    do: save(socket, :fold_night, !socket.assigns.preferences.fold_night)

  defp save(socket, key, value) do
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
