defmodule Tymeslot.Integrations.Shared.HttpAuth do
  @moduledoc """
  Authorization headers for the provider API clients.
  """

  @doc """
  The `Authorization` header carrying an OAuth access token.
  """
  @spec bearer(String.t()) :: {String.t(), String.t()}
  def bearer(token) when is_binary(token), do: {"Authorization", "Bearer " <> token}
end
