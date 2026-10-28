defmodule TymeslotWeb.Dashboard.Polls.PollReminders.Events do
  @moduledoc """
  The reminder picker's events, prefixed `poll_`, that the poll form and the
  poll editor route to `TymeslotWeb.Dashboard.Polls.PollReminders.apply_event/3`.

  Their owners read the list at compile time, for a `handle_event/3` guard.
  It lives in a module that depends on nothing, so that read does not tie
  them to everything the picker itself depends on.
  """

  # `poll_commit_custom_reminder` comes from the picker's `ReminderCustomRow`
  # hook when focus leaves the custom row with a value still in it.
  @events ~w(poll_add_quick_reminder poll_add_reminder poll_remove_reminder
             poll_toggle_custom_reminder poll_update_reminder_input
             poll_commit_custom_reminder)

  @doc "The picker's events."
  @spec all() :: [String.t()]
  def all, do: @events
end
