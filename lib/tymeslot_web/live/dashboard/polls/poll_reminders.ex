defmodule TymeslotWeb.Dashboard.Polls.PollReminders do
  @moduledoc """
  The reminder picker as the poll create form and the poll editor use it:
  reminders go out before the voting deadline to everyone who has not voted,
  so the one-click choices are days rather than minutes.

  The owning LiveComponent keeps a `ReminderPickerState` and routes the
  picker's events (`events/0`) through `apply_event/3`. Before saving the poll it runs `commit_pending/1`, so a lead time typed into the custom row but never added is not lost. The picker sits in a
  form of its own, so it must be rendered outside the poll's main form.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.MeetingTypes.ReminderValidation
  alias TymeslotWeb.Components.Shared.{ReminderPicker, ReminderPickerState}

  @events ~w(poll_add_quick_reminder poll_add_reminder poll_remove_reminder
             poll_toggle_custom_reminder poll_update_reminder_input
             poll_commit_custom_reminder)

  @doc "The picker events, prefixed `poll_`, that the owner routes to `apply_event/3`."
  @spec events() :: [String.t()]
  def events, do: @events

  @doc "A picker holding `reminders`."
  @spec new([map()]) :: ReminderPickerState.t()
  def new(reminders), do: ReminderPickerState.new(reminders)

  @doc "Applies one picker event to `state`."
  @spec apply_event(String.t(), ReminderPickerState.t(), map()) :: ReminderPickerState.t()
  def apply_event(event, state, params) do
    {_changed, state} =
      case event do
        "poll_add_quick_reminder" -> ReminderPickerState.add_quick(state, params)
        "poll_add_reminder" -> ReminderPickerState.add_custom(state, params)
        "poll_remove_reminder" -> ReminderPickerState.remove(state, params)
        "poll_toggle_custom_reminder" -> ReminderPickerState.toggle_custom(state)
        "poll_update_reminder_input" -> ReminderPickerState.update_input(state, params)
        "poll_commit_custom_reminder" -> ReminderPickerState.commit_pending(state, params)
      end

    state
  end

  @doc "The reminders held, as a poll's `reminder_config`."
  @spec to_config(ReminderPickerState.t()) :: [map()]
  def to_config(%{reminders: reminders}),
    do: Enum.map(reminders, &%{"value" => &1.value, "unit" => &1.unit})

  @doc """
  Adds what the open custom row still holds, for an owner about to save the
  poll, as the meeting type form and Quick Add do: a typed lead time is the
  host's intent even if Add was never pressed. A value that fails
  validation answers `{:error, state}` with the picker's own message, and
  the save should stop there.
  """
  @spec commit_pending(ReminderPickerState.t()) ::
          {:ok, ReminderPickerState.t()} | {:error, ReminderPickerState.t()}
  def commit_pending(state) do
    if ReminderPickerState.pending?(state) do
      case ReminderPickerState.add_custom(state) do
        {:ok, added} -> {:ok, added}
        {:noop, rejected} -> {:error, rejected}
      end
    else
      {:ok, state}
    end
  end

  attr :id, :string, required: true
  attr :state, :map, required: true
  attr :myself, :any, required: true

  @doc "The picker in its own form."
  @spec reminders_form(map()) :: Phoenix.LiveView.Rendered.t()
  def reminders_form(assigns) do
    ~H"""
    <%!-- A form of its own, so Enter in the custom number adds the reminder
          instead of submitting the poll. --%>
    <form
      id={@id}
      phx-change="poll_update_reminder_input"
      phx-submit="poll_add_reminder"
      phx-target={@myself}
      data-testid="poll-reminders-form"
    >
      <ReminderPicker.reminder_picker
        reminders={@state.reminders}
        max_reminders={ReminderValidation.max_reminders()}
        new_reminder_value={@state.new_reminder_value}
        new_reminder_unit={@state.new_reminder_unit}
        reminder_error={@state.reminder_error}
        show_custom_reminder={@state.show_custom_reminder}
        reminder_confirmation={@state.reminder_confirmation}
        description={
          dgettext(
            "dashboard_polls",
            "Sent before the voting deadline to everyone who has not voted yet. A poll without a deadline sends none."
          )
        }
        presets={[%{value: 1, unit: "days"}, %{value: 3, unit: "days"}]}
        event_prefix="poll_"
        myself={@myself}
      />
    </form>
    """
  end
end
