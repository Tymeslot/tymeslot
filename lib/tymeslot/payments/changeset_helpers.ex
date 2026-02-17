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
end
