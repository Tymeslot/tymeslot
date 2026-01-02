defmodule Tymeslot.Integrations.Shared.OAuth.TokenFlow do
  @moduledoc """
  Shared helpers for performing OAuth token exchanges and refreshes.
  """

  alias Tymeslot.Infrastructure.HTTPClient

  @default_headers [{"Content-Type", "application/x-www-form-urlencoded"}]

  @type token_error ::
          {:http_error, integer(), String.t()}
          | {:network_error, any()}

  @spec exchange_code(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, token_error()}
  def exchange_code(token_url, params, opts \\ []) do
    request_tokens(token_url, params, opts)
  end

  @spec refresh_token(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, token_error()}
  def refresh_token(token_url, params, opts \\ []) do
    request_tokens(token_url, params, opts)
  end

  defp request_tokens(token_url, params, opts) do
    headers = Keyword.get(opts, :headers, @default_headers)

    case HTTPClient.request(:post, token_url, URI.encode_query(params), headers) do
      {:ok, %{status_code: 200, body: body}} ->
        {:ok, Jason.decode!(body)}

      {:ok, %{status_code: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, {:network_error, reason}}
    end
  end
end
