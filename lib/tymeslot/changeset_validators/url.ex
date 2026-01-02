defmodule Tymeslot.ChangesetValidators.URL do
  @moduledoc """
  Shared Ecto changeset URL validator used across schemas.
  Ensures HTTP/HTTPS scheme and a non-empty host. Limits length and blocks risky schemes.
  """
  import Ecto.Changeset

  @max_len 2000

  @spec validate_url(Ecto.Changeset.t(), atom(), keyword()) :: Ecto.Changeset.t()
  def validate_url(changeset, field, _opts \\ []) do
    validate_change(changeset, field, fn ^field, value ->
      case URI.parse(value) do
        %URI{scheme: scheme, host: host}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          cond do
            String.length(value) > @max_len ->
              [{field, "URL must be #{@max_len} characters or less"}]

            String.contains?(value, ["javascript:", "data:", "file:", "ftp:"]) ->
              [{field, "Only HTTP and HTTPS URLs are allowed"}]

            true ->
              []
          end

        _ ->
          [{field, "must be a valid HTTP or HTTPS URL"}]
      end
    end)
  end
end
