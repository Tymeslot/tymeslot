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

  @type t :: %{
          show_week_numbers: boolean(),
          sets: [%{position: 1..9, name: String.t()}],
          active_set: 0..9,
          focus: boolean(),
          desktop_reminders: boolean()
        }

  @spec settings(map()) :: t()
  def settings(_assigns) do
    %{show_week_numbers: false, sets: [], active_set: 0, focus: false, desktop_reminders: false}
  end
end
