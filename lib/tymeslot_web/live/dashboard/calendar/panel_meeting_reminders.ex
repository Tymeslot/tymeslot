defmodule TymeslotWeb.Dashboard.Calendar.PanelMeetingReminders do
  @moduledoc """
  The reminder emails of a Tymeslot meeting booked from the side panel's New
  event state (`PanelMeeting`): the shared reminder picker
  (`TymeslotWeb.Components.Shared.ReminderPicker`), as the meeting type form
  and polls offer it, so any lead time a meeting type could have, up to
  `ReminderValidation.max_reminders/0` of them, with the common ones a
  click away.

  The picker's state (`ReminderPickerState`) is the panel's
  `:reminder_picker`. The picker is drawn inside the New event form, so its
  events arrive as `panel:meeting_<name>` (`event/3`), and Enter
  in its custom row submits that form with an empty guest field, which adds
  the typed lead time instead (`add_typed/2`). Creating the meeting adds a
  lead time typed but never added (`commit_pending/1`), as the other forms
  do: it is the host's intent even if Add was never pressed.
  """

  import Phoenix.Component, only: [assign: 3]

  alias TymeslotWeb.Components.Shared.ReminderPickerState

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc "The picker a new draft starts with: no reminders."
  @spec new() :: ReminderPickerState.t()
  def new, do: ReminderPickerState.new([])

  @doc "The panel's picker."
  @spec state(map()) :: ReminderPickerState.t()
  def state(panel), do: Map.get(panel, :reminder_picker) || new()

  @doc "Applies the picker event `name` to the New event panel's picker."
  @spec event(socket(), String.t(), map()) :: socket()
  def event(%{assigns: %{panel: %{mode: :new, status: status} = panel}} = socket, name, params)
      when status != :saving do
    {_changed, picker} = apply_event(name, state(panel), params)
    assign(socket, :panel, Map.put(panel, :reminder_picker, picker))
  end

  def event(socket, _name, _params), do: socket

  defp apply_event("meeting_add_quick_reminder", picker, params),
    do: ReminderPickerState.add_quick(picker, params)

  defp apply_event("meeting_add_reminder", picker, params),
    do: ReminderPickerState.add_custom(picker, params)

  defp apply_event("meeting_remove_reminder", picker, params),
    do: ReminderPickerState.remove(picker, params)

  defp apply_event("meeting_toggle_custom_reminder", picker, _params),
    do: ReminderPickerState.toggle_custom(picker)

  defp apply_event("meeting_update_reminder_input", picker, params),
    do: ReminderPickerState.update_input(picker, params)

  defp apply_event("meeting_commit_custom_reminder", picker, params),
    do: ReminderPickerState.commit_pending(picker, params)

  @doc """
  Enter in the form with no guest typed: adds the lead time the custom row
  holds, if it holds one, as Enter there does in the other forms.
  """
  @spec add_typed(socket(), map()) :: socket()
  def add_typed(%{assigns: %{panel: %{mode: :new} = panel}} = socket, params) do
    if ReminderPickerState.pending?(state(panel), params),
      do: event(socket, "meeting_add_reminder", params),
      else: socket
  end

  def add_typed(socket, _params), do: socket

  @doc """
  The panel's picker with a lead time typed but never added now added, for
  a meeting about to be created: `{:ok, picker}`, or `{:error, picker}`
  holding the picker's own message when the typed one cannot be added.
  """
  @spec commit_pending(map()) ::
          {:ok, ReminderPickerState.t()} | {:error, ReminderPickerState.t()}
  def commit_pending(panel) do
    picker = state(panel)

    if ReminderPickerState.pending?(picker) do
      case ReminderPickerState.add_custom(picker) do
        {:ok, added} -> {:ok, added}
        {:noop, rejected} -> {:error, rejected}
      end
    else
      {:ok, picker}
    end
  end
end
