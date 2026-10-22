defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.ReminderHandlers do
  @moduledoc """
  The reminder picker's events for `MeetingTypeForm`. Each works on the
  picker's own state (`TymeslotWeb.Components.Shared.ReminderPickerState`),
  lifted out of the form's assigns and written straight back.

  Split out of the form to keep it inside the size limit.
  """

  import Phoenix.Component, only: [assign: 2]

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Components.Shared.ReminderPickerState
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.Autosave

  @events ~w(update_reminder_input toggle_custom_reminder add_quick_reminder add_reminder
             commit_custom_reminder remove_reminder)

  @doc "The events handled here, for the form to route to `handle_event/3`."
  @spec events() :: [String.t()]
  def events, do: @events

  @doc "Applies one of `events/0` to the form's socket."
  @spec handle_event(String.t(), map(), Socket.t()) :: Socket.t()
  def handle_event("update_reminder_input", params, socket),
    do:
      socket |> picker_state() |> ReminderPickerState.update_input(params) |> apply_state(socket)

  def handle_event("toggle_custom_reminder", _params, socket),
    do: socket |> picker_state() |> ReminderPickerState.toggle_custom() |> apply_state(socket)

  def handle_event("add_quick_reminder", params, socket),
    do: socket |> picker_state() |> ReminderPickerState.add_quick(params) |> apply_state(socket)

  def handle_event("add_reminder", _params, socket),
    do: socket |> picker_state() |> ReminderPickerState.add_custom() |> apply_state(socket)

  def handle_event("commit_custom_reminder", params, socket),
    do:
      socket
      |> picker_state()
      |> ReminderPickerState.commit_pending(params)
      |> apply_state(socket)

  def handle_event("remove_reminder", params, socket),
    do: socket |> picker_state() |> ReminderPickerState.remove(params) |> apply_state(socket)

  # The reminder picker's own state, as the shared module keeps it. The form
  # holds each field as an assign of its own, so it is lifted out for the
  # picker to work on and written straight back.
  defp picker_state(socket) do
    Map.take(socket.assigns, [
      :reminders,
      :new_reminder_value,
      :new_reminder_unit,
      :reminder_error,
      :show_custom_reminder,
      :reminder_confirmation
    ])
  end

  # A change to the list is worth saving, and starts the timer that takes the
  # confirmation back down; anything else (a keystroke in the custom row, a
  # rejected reminder) only updates what is on screen.
  defp apply_state({:ok, state}, socket) do
    Process.send_after(self(), {:clear_reminder_confirmation, socket.assigns.id}, 3000)

    socket |> assign(state) |> Autosave.maybe_run()
  end

  defp apply_state({:noop, state}, socket), do: assign(socket, state)
end
