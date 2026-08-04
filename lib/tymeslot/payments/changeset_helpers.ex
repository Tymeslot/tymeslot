defmodule Tymeslot.Payments.ChangesetHelpers do
  @moduledoc false

  @spec unique_pending_transaction_error?(Ecto.Changeset.t()) :: boolean()
  def unique_pending_transaction_error?(%Ecto.Changeset{} = changeset) do
    case changeset.errors[:user_id] do
      {msg, _opts} ->
        String.contains?(msg, "has already been taken")

      errors when is_list(errors) ->
        Enum.any?(errors, fn {msg, _opts} ->
          String.contains?(msg, "has already been taken")
        end)

      _other ->
        false
    end
  end

  @doc """
  Whether any error on the changeset came from a database constraint
  (unique, foreign key, check) rather than a plain field validation.

  A constraint violation reflects the database rejecting the write for a
  reason outside the changeset's own data (most often a race with a
  concurrent write), so it may succeed if retried. A validation error
  (`validate_required`, an `Ecto.Enum` cast failure, …) is deterministic:
  the same input fails identically every time, so retrying is pointless.
  """
  @spec constraint_violation?(Ecto.Changeset.t()) :: boolean()
  def constraint_violation?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
      Keyword.has_key?(opts, :constraint)
    end)
  end
end
