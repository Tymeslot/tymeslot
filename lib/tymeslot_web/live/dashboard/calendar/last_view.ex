defmodule TymeslotWeb.Dashboard.Calendar.LastView do
  @moduledoc """
  Remembers the view the organiser last chose on a desktop, so the calendar
  opens on it next time: the stored `default_view`, which
  `SurfaceData.target/1` reads when the URL names no view.

  Day, week, month and agenda are remembered. Three days is not (it is a
  phone's week, and `default_view` cannot hold it), and nothing chosen on a
  phone is, so a phone never changes what the desktop opens on.
  `SurfaceData.follow/2` calls this when the URL moves to another period,
  never on the first load, so a link that names a view leaves the default
  alone. A failed save changes nothing the organiser sees and is not
  reported.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.CalendarGrid

  @remembered [:day, :week, :month, :agenda]

  @doc "Saves the view shown as `default_view` when it is a desktop's and differs."
  @spec remember(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def remember(%{assigns: %{viewport: :wide, view: view, preferences: preferences}} = socket)
      when view in @remembered do
    value = Atom.to_string(view)

    if value == preferences.default_view, do: socket, else: save(socket, value)
  end

  def remember(socket), do: socket

  defp save(socket, value) do
    case CalendarGrid.save_preferences(socket.assigns.current_user.id, %{default_view: value}) do
      {:ok, _preferences} ->
        assign(socket, :preferences, %{socket.assigns.preferences | default_view: value})

      {:error, _changeset} ->
        socket
    end
  end
end
