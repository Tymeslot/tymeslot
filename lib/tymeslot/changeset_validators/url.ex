defmodule Tymeslot.ChangesetValidators.URL do
  @moduledoc """
  Shared Ecto changeset URL validator used across schemas.

  Delegates to `Tymeslot.Security.UrlValidation.validate_http_url/2` so that
  every changeset-validated URL gets the same SSRF protection, length checks,
  and protocol blocking. Length limit comes from `Validation.Constraints`.
  """

  import Ecto.Changeset

  alias Tymeslot.Security.UrlValidation
  alias Tymeslot.Validation.Constraints

  @spec validate_url(Ecto.Changeset.t(), atom(), keyword()) :: Ecto.Changeset.t()
  def validate_url(changeset, field, validation_opts \\ []) do
    validate_change(changeset, field, fn ^field, value ->
      opts =
        Keyword.merge(
          [max_length: Constraints.url_max_length()],
          validation_opts
        )

      case UrlValidation.validate_http_url(value, opts) do
        :ok -> []
        {:error, message} -> [{field, message}]
      end
    end)
  end
end
