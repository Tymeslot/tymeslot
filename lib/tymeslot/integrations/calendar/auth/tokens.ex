defmodule Tymeslot.Integrations.Calendar.Tokens do
  @moduledoc """
  Token refresh utilities for OAuth-based calendar providers.

  Centralizes token expiry checks and refresh flows for Google and Outlook.
  """

  alias Tymeslot.DatabaseQueries.CalendarIntegrationQueries
  alias Tymeslot.DatabaseSchemas.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Auth.TokenRefreshLock
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI, as: GoogleCalendarAPI
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookCalendarAPI
  alias Tymeslot.Integrations.Calendar.TokenUtils

  @type integration :: map()
  @type user_id :: pos_integer()

  @provider_map %{
    "google" => :google,
    "outlook" => :outlook
  }

  @doc """
  Ensure an integration has a valid access token, refreshing if needed.
  Returns {:ok, updated_integration} or {:error, :token_refresh_failed | :unsupported_provider}.
  """
  @spec ensure_valid_token(integration(), user_id()) :: {:ok, integration()} | {:error, term()}
  def ensure_valid_token(integration, _user_id) do
    if TokenUtils.token_expired?(integration) do
      refresh_oauth_token(integration)
    else
      {:ok, integration}
    end
  end

  @doc """
  Refresh the access token for an integration.
  Persists refreshed credentials when possible.
  """
  @spec refresh_oauth_token(integration()) :: {:ok, integration()} | {:error, term()}
  def refresh_oauth_token(%{provider: provider} = integration)
      when provider in ["google", "outlook"] do
    integration_id = Map.get(integration, :id) || Map.get(integration, "id") || :unknown
    provider_atom = Map.get(@provider_map, provider)

    if integration_id == :unknown or is_nil(provider_atom) do
      perform_refresh(integration)
    else
      # Ensure integration_id is an integer if it's a string
      integration_id =
        case integration_id do
          id when is_integer(id) ->
            id

          id when is_binary(id) ->
            case Integer.parse(id) do
              {int, ""} -> int
              _ -> :unknown
            end

          _ ->
            :unknown
        end

      if integration_id == :unknown do
        perform_refresh(integration)
      else
        TokenRefreshLock.with_lock(provider_atom, integration_id, fn ->
          # Re-fetch from DB to ensure we have the most up-to-date tokens
          # (in case another process just refreshed them while we were waiting for the lock)
          integration =
            case CalendarIntegrationQueries.get(integration_id) do
              {:ok, fresh_integration} -> fresh_integration
              _ -> integration
            end

          if TokenUtils.token_expired?(integration) do
            perform_refresh(integration)
          else
            {:ok, integration}
          end
        end)
      end
    end
  end

  def refresh_oauth_token(_), do: {:error, :unsupported_provider}

  defp perform_refresh(%{provider: "google"} = integration) do
    case google_calendar_api().refresh_token(integration) do
      {:ok, {new_access_token, new_refresh_token, expires_at}} ->
        # Use new refresh token if provided (rotation), else keep old one
        refresh_to_persist =
          if is_binary(new_refresh_token) and new_refresh_token != "",
            do: new_refresh_token,
            else: Map.get(integration, :refresh_token)

        persist_and_return(
          integration,
          new_access_token,
          refresh_to_persist,
          expires_at
        )

      {:error, type, msg} ->
        {:error, {type, msg}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp perform_refresh(%{provider: "outlook"} = integration) do
    case outlook_calendar_api().refresh_token(integration) do
      {:ok, {new_access_token, new_refresh_token, expires_at}} ->
        persist_and_return(integration, new_access_token, new_refresh_token, expires_at)

      {:error, type, msg} ->
        {:error, {type, msg}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Best-effort persistence: if we have a schema struct, write to DB; otherwise
  # return the updated map.
  defp persist_and_return(%CalendarIntegrationSchema{} = integration, access, refresh, expires_at) do
    attrs = %{
      access_token: access,
      refresh_token: refresh,
      token_expires_at: expires_at,
      sync_error: nil
    }

    case CalendarIntegrationQueries.update_integration(integration, attrs) do
      {:ok, updated} ->
        {:ok, CalendarIntegrationSchema.decrypt_oauth_tokens(updated)}

      {:error, _} ->
        {:ok,
         %{
           integration
           | access_token: access,
             refresh_token: refresh,
             token_expires_at: expires_at
         }}
    end
  end

  defp persist_and_return(integration, access, refresh, expires_at) when is_map(integration) do
    {:ok,
     Map.merge(integration, %{
       access_token: access,
       refresh_token: refresh,
       token_expires_at: expires_at
     })}
  end

  defp google_calendar_api do
    Application.get_env(:tymeslot, :google_calendar_api_module, GoogleCalendarAPI)
  end

  defp outlook_calendar_api do
    Application.get_env(:tymeslot, :outlook_calendar_api_module, OutlookCalendarAPI)
  end
end
