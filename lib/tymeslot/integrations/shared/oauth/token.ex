defmodule Tymeslot.Integrations.Common.OAuth.Token do
  @moduledoc """
  Common helpers for validating and refreshing OAuth access tokens.

  This module centralizes token validity checks and the pattern for ensuring
  a usable access token, reducing duplication across provider clients.
  """

  alias Tymeslot.DatabaseQueries.CalendarIntegrationQueries
  alias Tymeslot.DatabaseSchemas.CalendarIntegrationSchema

  @type integration :: map()
  @type decrypt_fun :: (integration() -> integration())
  @type refresh_fun :: (integration() ->
                          {:ok, {String.t(), String.t(), DateTime.t()}}
                          | {:error, any()}
                          | {:error, atom(), any()})

  @doc """
  Returns true if the integration token is valid with a buffer (in seconds).

  Defaults to a 5 minute (300s) buffer to proactively refresh tokens.
  """
  @spec valid?(integration(), non_neg_integer()) :: boolean()
  def valid?(integration, buffer_seconds \\ 300)
  def valid?(%{token_expires_at: nil}, _buffer_seconds), do: false

  def valid?(%{token_expires_at: expires_at}, buffer_seconds) do
    DateTime.compare(expires_at, DateTime.add(DateTime.utc_now(), buffer_seconds, :second)) == :gt
  end

  @doc """
  Ensures a valid access token is available for the given integration.

  Options:
    - :decrypt_fun - function to decrypt tokens on the integration (default: identity)
    - :refresh_fun - REQUIRED function to refresh tokens, returns {:ok, {access, refresh, expires_at}} or {:error, ...}
    - :buffer_seconds - seconds before expiry to consider invalid (default: 300)
    - :persist - when true (default), persist refreshed tokens to storage when possible

  Returns {:ok, access_token} or {:error, reason}.
  """
  @spec ensure_valid_access_token(integration(), keyword()) :: {:ok, String.t()} | {:error, any()}
  def ensure_valid_access_token(integration, opts) when is_map(integration) and is_list(opts) do
    decrypt_fun = Keyword.get(opts, :decrypt_fun, &Function.identity/1)
    refresh_fun = Keyword.fetch!(opts, :refresh_fun)
    buffer_seconds = Keyword.get(opts, :buffer_seconds, 300)
    persist? = Keyword.get(opts, :persist, true)

    if valid?(integration, buffer_seconds) do
      integration
      |> decrypt_fun.()
      |> then(fn decrypted ->
        {:ok, Map.get(decrypted, :access_token) || Map.get(decrypted, "access_token")}
      end)
    else
      refresh_and_persist(integration, refresh_fun, persist?)
    end
  end

  defp refresh_and_persist(integration, refresh_fun, persist?) do
    integration_id = Map.get(integration, :id) || Map.get(integration, "id") || :no_id

    result = :global.trans({:token_refresh, integration_id}, fn -> refresh_fun.(integration) end)

    case result do
      {:ok, {access_token, refresh_token, expires_at}} ->
        _ = if persist?, do: persist_tokens(integration, access_token, refresh_token, expires_at)
        {:ok, access_token}

      {:error, type, reason} ->
        {:error, type, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Best-effort persistence of refreshed tokens; no-ops on failure
  defp persist_tokens(%CalendarIntegrationSchema{} = integration, access, refresh, expires_at) do
    attrs = %{
      access_token: access,
      refresh_token: refresh,
      token_expires_at: expires_at
    }

    case CalendarIntegrationQueries.update_integration(integration, attrs) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  defp persist_tokens(%{id: id}, access, refresh, expires_at) when is_integer(id) do
    case CalendarIntegrationQueries.get(id) do
      {:ok, %CalendarIntegrationSchema{} = integ} ->
        persist_tokens(integ, access, refresh, expires_at)

      _ ->
        :ok
    end
  end

  defp persist_tokens(_integration, _access, _refresh, _expires_at), do: :ok
end
