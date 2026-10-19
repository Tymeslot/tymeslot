defmodule TymeslotWeb.Dashboard.Calendar.PowerSettings do
  @moduledoc """
  The power layer's share of the settings the `CalendarCanvas` hook draws
  and reads its keys with, merged into `SurfaceData.settings/1`, so they
  travel in every `calendar:settings` push and every `calendar:events`
  payload:

    * `show_week_numbers`: whether the grid, the month and the mini month
      number their weeks,
    * `sets`: the organiser's calendar sets as `%{position: 1..9, name: name}`,
      which the digit keys and the command bar offer,
    * `active_set`: the active set's position, 0 for none,
    * `focus`: whether focus mode hides the dashboard menu,
    * `desktop_reminders`: whether desktop notifications are on.

  Every key is always sent, at its default until the task that gives it a
  control fills it, so the hook never meets a missing one.
  """

  import Phoenix.Component, only: [assign: 2]

  alias TymeslotWeb.Dashboard.Calendar.SurfaceData

  @type t :: %{
          show_week_numbers: boolean(),
          sets: [%{position: 1..9, name: String.t()}],
          active_set: 0..9,
          focus: boolean(),
          desktop_reminders: boolean()
        }

  @spec settings(map()) :: t()
  def settings(assigns) do
    %{
      show_week_numbers: assigns.preferences.show_week_numbers,
      sets:
        for(
          set <- Map.get(assigns, :calendar_sets, []),
          do: %{position: set.position, name: set.name}
        ),
      active_set: active_position(Map.get(assigns, :active_set)),
      focus: Map.get(assigns, :calendar_focus) == true,
      desktop_reminders: assigns.preferences.desktop_reminders_enabled
    }
  end

  defp active_position(%{position: position}), do: position
  defp active_position(nil), do: 0

  @doc """
  Assigns the parent's attributes and, when its `calendar_focus` changed in
  this update, pushes the settings again, so the hook's `focus` follows a
  toggle from the toolbar, display options or F (or a tour ending). The
  first update of a mount pushes nothing: the hook asks for its settings.
  """
  @spec assign_parent(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def assign_parent(%{assigns: %{ready?: true, calendar_focus: was}} = socket, assigns)
      when is_boolean(was) do
    socket = assign(socket, assigns)

    if socket.assigns.calendar_focus == was,
      do: socket,
      else: SurfaceData.push_settings(socket)
  end

  def assign_parent(socket, assigns), do: assign(socket, assigns)
end
