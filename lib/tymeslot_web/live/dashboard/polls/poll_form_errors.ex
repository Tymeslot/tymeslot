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
  alias TymeslotWeb.Helpers.FormErrors

  @reasons [:too_many_slots, :slot_in_past, :payment_required_type, :meeting_type_not_found]

  @doc "Whether `errors_for/2` has an error for `reason`."
  @spec shared_reason?(term()) :: boolean()
  def shared_reason?(reason), do: reason in @reasons

  @doc "The errors for `reason`, with any about the times under `slots_field`."
  @spec errors_for(atom(), atom()) :: %{atom() => [String.t()]}
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
