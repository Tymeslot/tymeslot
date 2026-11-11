defmodule TymeslotWeb.Dashboard.Polls.PollFormErrors do
  @moduledoc """
  The inline errors the poll forms show for what `Tymeslot.Polls` refuses,
  shared by the create form (`PollForm`) and the editor (`PollEditor`).

  Errors are a map of field to a list of messages. The candidate times sit
  under a different field in each form (`:slots` when creating, `:new_times`
  when editing), so the errors about them are put under the field the
  caller names.
  """
  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset
  alias Tymeslot.Polls.PollSchema
  alias TymeslotWeb.Components.CoreComponents.DateTimePicker.Value
  alias TymeslotWeb.Helpers.FormErrors

  @reasons [:too_many_slots, :slot_in_past, :payment_required_type, :meeting_type_not_found]

  @doc "Whether `errors_for/2` has an error for `reason`."
  @spec shared_reason?(term()) :: boolean()
  def shared_reason?(reason), do: reason in @reasons

  @doc "The errors for `reason`, with any about the times under `slots_field`."
  @spec errors_for(atom() | {:unfinished_times, map()}, atom()) :: %{atom() => [String.t()]}
  def errors_for({:unfinished_times, errors}, _slots_field), do: errors

  def errors_for(:no_slots, slots_field),
    do: %{slots_field => [dgettext("dashboard_polls", "Add at least one candidate time")]}

  def errors_for(:too_many_slots, slots_field), do: %{slots_field => [too_many_message()]}

  def errors_for(:slot_in_past, slots_field),
    do: %{slots_field => [dgettext("dashboard_polls", "Times must be in the future")]}

  def errors_for(:payment_required_type, _slots_field),
    do: %{
      meeting_type_id: [
        dgettext("dashboard_polls", "Paid meeting types can't be used for polls")
      ]
    }

  def errors_for(:meeting_type_not_found, _slots_field),
    do: %{meeting_type_id: [dgettext("dashboard_polls", "That meeting type is unavailable")]}

  @doc """
  The errors on a poll changeset, with the deadline's replaced by one that
  says what the host has to change.
  """
  @spec changeset_errors(Changeset.t()) :: map()
  def changeset_errors(%Changeset{} = changeset) do
    errors = FormErrors.to_map(changeset)

    if Map.has_key?(errors, :deadline_at),
      do:
        Map.put(errors, :deadline_at, [
          dgettext("dashboard_polls", "The deadline must be in the future")
        ]),
      else: errors
  end

  @doc """
  Refuses a save when the deadline, or any of the time rows under
  `rows_param`, is a date with no time (or a time with no date), rather than
  read it as blank. The error's map goes to the form's errors: a half-filled
  row shows its own message under it, so a form refused for its rows alone
  gets an empty map, with nothing to add but nothing saved without the row.
  """
  @spec finished_times(map(), String.t()) :: :ok | {:error, {:unfinished_times, map()}}
  def finished_times(params, rows_param) do
    rows = Map.get(params, rows_param)
    rows_unfinished? = is_map(rows) and Enum.any?(Map.values(rows), &Value.unfinished/1)

    case Value.unfinished(Map.get(params, "deadline")) do
      nil when rows_unfinished? -> {:error, {:unfinished_times, %{}}}
      nil -> :ok
      reason -> {:error, {:unfinished_times, %{deadline_at: [Value.message(reason)]}}}
    end
  end

  @doc "The error for one time too many."
  @spec too_many_message() :: String.t()
  def too_many_message,
    do: dgettext("dashboard_polls", "Up to %{max} times", max: PollSchema.max_slots())

  @doc "The messages for `field`, as a list for the field's `errors`."
  @spec error_list(map(), atom()) :: [String.t()]
  def error_list(errors, field) do
    case Map.get(errors, field) do
      nil -> []
      messages when is_list(messages) -> messages
      message -> [message]
    end
  end
end
