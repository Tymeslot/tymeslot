defmodule Tymeslot.Integrations.Common.OAuth.Token do
  @moduledoc """
  Common helpers for validating and refreshing OAuth access tokens.

  This module centralizes token validity checks and the pattern for ensuring
  a usable access token, reducing duplication across provider clients.
  """

  alias Tymeslot.DatabaseQueries.CalendarIntegrationQueries
  alias Tymeslot.DatabaseSchemas.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Shared.Lock

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
  @default_lock_timeout_ms 60_000

  @spec ensure_valid_access_token(integration(), keyword()) :: {:ok, String.t()} | {:error, any()}
  def ensure_valid_access_token(integration, opts) when is_map(integration) and is_list(opts) do
    decrypt_fun = Keyword.get(opts, :decrypt_fun, &Function.identity/1)
    refresh_fun = Keyword.fetch!(opts, :refresh_fun)
    buffer_seconds = Keyword.get(opts, :buffer_seconds, 300)
    persist? = Keyword.get(opts, :persist, true)
    refetch_fun = Keyword.get(opts, :refetch_fun)
    lock_timeout = Keyword.get(opts, :lock_timeout, @default_lock_timeout_ms)

    if valid?(integration, buffer_seconds) do
      integration
      |> decrypt_fun.()
      |> then(fn decrypted ->
        {:ok, Map.get(decrypted, :access_token) || Map.get(decrypted, "access_token")}
      end)
    else
      refresh_and_persist(
        integration,
        refresh_fun,
        persist?,
        decrypt_fun,
        buffer_seconds,
        refetch_fun,
        lock_timeout
      )
    end
  end

  defp refresh_and_persist(
         integration,
         refresh_fun,
         persist?,
         decrypt_fun,
         buffer_seconds,
         refetch_fun,
         lock_timeout
       ) do
    integration_id = Map.get(integration, :id) || Map.get(integration, "id") || :no_id

    lock_result =
      Lock.with_lock(
        {:token_refresh, integration_id},
        fn ->
          # Re-fetch from DB and re-validate to avoid redundant refreshes
          # when another caller already refreshed while we waited for the lock
          case maybe_refetch_valid_token(integration_id, refetch_fun, decrypt_fun, buffer_seconds) do
            {:ok, _access_token} = already_valid ->
              already_valid

            :stale ->
              refresh_fun.(integration)
          end
        end,
        mode: :blocking,
        timeout: lock_timeout
      )

    case lock_result do
      {:error, :lock_timeout} ->
        {:error, :lock_timeout}

      {:error, :lock_manager_not_started} ->
        # Fallback: run without lock if Lock GenServer isn't running
        handle_refresh_result(refresh_fun.(integration), integration, persist?)

      result ->
        handle_refresh_result(result, integration, persist?)
    end
  end

  defp handle_refresh_result(result, integration, persist?) do
    case result do
      {:ok, access_token} when is_binary(access_token) ->
        # Token was already valid from refetch — no persistence needed
        {:ok, access_token}

      {:ok, {access_token, refresh_token, expires_at}} ->
        _persist_result =
          if persist?, do: persist_tokens(integration, access_token, refresh_token, expires_at)

        {:ok, access_token}

      {:error, type, reason} ->
        {:error, type, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_refetch_valid_token(_integration_id, nil, _decrypt_fun, _buffer_seconds), do: :stale

  defp maybe_refetch_valid_token(integration_id, refetch_fun, decrypt_fun, buffer_seconds) do
    case refetch_fun.(integration_id) do
      %{} = fresh ->
        if valid?(fresh, buffer_seconds) do
          decrypted = decrypt_fun.(fresh)
          {:ok, Map.get(decrypted, :access_token) || Map.get(decrypted, "access_token")}
        else
          :stale
        end

      {:ok, %{} = fresh} ->
        if valid?(fresh, buffer_seconds) do
          decrypted = decrypt_fun.(fresh)
          {:ok, Map.get(decrypted, :access_token) || Map.get(decrypted, "access_token")}
        else
          :stale
        end

      _error ->
        :stale
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
      {:ok, _updated_integration} -> :ok
      {:error, _update_error} -> :ok
    end
  end

  defp persist_tokens(%{id: id}, access, refresh, expires_at) when is_integer(id) do
    case CalendarIntegrationQueries.get(id) do
      {:ok, %CalendarIntegrationSchema{} = integ} ->
        persist_tokens(integ, access, refresh, expires_at)

      {:error, _fetch_error} ->
        :ok
    end
  end

  defp persist_tokens(_integration, _access, _refresh, _expires_at), do: :ok
end
