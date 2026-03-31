defmodule Tymeslot.ChangesetValidators.Email do
  @moduledoc """
  Shared changeset validator for email fields.

  Delegates to `Tymeslot.Security.FieldValidators.EmailValidator` so that
  every email field — whether on a user, meeting, or any other schema —
  goes through the same comprehensive format validation.
  """

  import Ecto.Changeset

  alias Tymeslot.Security.FieldValidators.EmailValidator

  @spec validate_email(Ecto.Changeset.t(), atom(), keyword()) :: Ecto.Changeset.t()
  def validate_email(changeset, field, opts \\ []) do
    validate_change(changeset, field, fn _field, email ->
      case EmailValidator.validate(email, opts) do
        :ok -> []
        {:error, message} -> [{field, message}]
      end
    end)
  end
end
