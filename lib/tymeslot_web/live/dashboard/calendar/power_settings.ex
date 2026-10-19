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
      sets: [],
      active_set: 0,
      focus: Map.get(assigns, :calendar_focus) == true,
      desktop_reminders: assigns.preferences.desktop_reminders_enabled
    }
  end

  @doc """
  Pushes the settings again when the parent's `calendar_focus` changed in
  this update (`was` is the value before it), so the hook's `focus` follows
  a toggle from the toolbar, display options or F. The first update of a
  mount (`was` nil) pushes nothing: the hook asks for its settings itself.
  """
  @spec follow_focus(Phoenix.LiveView.Socket.t(), boolean() | nil) ::
          Phoenix.LiveView.Socket.t()
  def follow_focus(%{assigns: %{ready?: true} = assigns} = socket, was)
      when is_boolean(was) do
    if Map.get(assigns, :calendar_focus) == was,
      do: socket,
      else: SurfaceData.push_settings(socket)
  end

  def follow_focus(socket, _was), do: socket
end
