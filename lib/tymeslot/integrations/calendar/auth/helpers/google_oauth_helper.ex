defmodule Tymeslot.Integrations.Calendar.Google.OAuthHelper do
  @moduledoc """
  Helper module for Google Calendar OAuth flow.

  This module provides functions to generate OAuth URLs and handle
  the OAuth callback for Google Calendar integration.
  """

  @behaviour Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour

  alias Tymeslot.DatabaseQueries.CalendarIntegrationQueries
  alias Tymeslot.Integrations.CalendarPrimary
  alias Tymeslot.Integrations.Common.OAuth.AccountMatch
  alias Tymeslot.Integrations.Google.GoogleOAuthHelper

  @doc """
  Generates the OAuth authorization URL for Google Calendar.

  Now requests full calendar scope to support Google Meet creation.
  """
  @impl Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour
  @spec authorization_url(pos_integer(), String.t()) :: String.t()
  def authorization_url(user_id, redirect_uri) do
    GoogleOAuthHelper.authorization_url(user_id, redirect_uri, [:calendar])
  end

  @doc """
  Generates the OAuth authorization URL for Google Calendar with specific scopes.
  """
  @impl Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour
  @spec authorization_url(pos_integer(), String.t(), list(atom() | String.t())) :: String.t()
  def authorization_url(user_id, redirect_uri, scopes) do
    GoogleOAuthHelper.authorization_url(user_id, redirect_uri, scopes)
  end

  @doc """
  Handles the OAuth callback and creates or updates a calendar integration.
  """
  @impl Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour
  @spec handle_callback(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def handle_callback(code, state, redirect_uri) do
    with {:ok, tokens} <- GoogleOAuthHelper.exchange_code_for_tokens(code, redirect_uri, state),
         {:ok, integration} <-
           create_or_update_calendar_integration(tokens.user_id, tokens, tokens[:integration_id]) do
      {:ok, integration}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Exchanges authorization code for access and refresh tokens.
  """
  @impl Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour
  @spec exchange_code_for_tokens(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def exchange_code_for_tokens(code, redirect_uri) do
    GoogleOAuthHelper.exchange_code_for_tokens(code, redirect_uri)
  end

  @doc """
  Refreshes an access token using a refresh token.
  """
  @impl Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour
  @spec refresh_access_token(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def refresh_access_token(refresh_token, current_scope \\ nil) do
    GoogleOAuthHelper.refresh_access_token(refresh_token, current_scope)
  end

  # Private functions

  defp create_or_update_calendar_integration(user_id, tokens, integration_id) do
    token_attrs = %{
      access_token: tokens.access_token,
      refresh_token: tokens.refresh_token,
      token_expires_at: tokens.expires_at,
      oauth_scope: tokens.scope,
      provider_account_id: tokens[:provider_account_id],
      provider_account_email: tokens[:provider_account_email]
    }

    cond do
      # Re-authorization of specific integration
      integration_id ->
        case CalendarIntegrationQueries.get_for_user(integration_id, user_id) do
          {:ok, existing} ->
            AccountMatch.verify_account_match(existing, tokens[:provider_account_id], fn ->
              update_existing_integration(existing, token_attrs)
            end)

          {:error, :not_found} ->
            {:error, "Integration not found"}
        end

      # New connection with known account
      is_binary(tokens[:provider_account_id]) ->
        case CalendarIntegrationQueries.get_by_account_for_user(
               user_id,
               "google",
               tokens[:provider_account_id]
             ) do
          {:ok, existing} ->
            update_existing_integration(existing, token_attrs)

          {:error, :not_found} ->
            create_new_google_integration(user_id, tokens[:provider_account_id], token_attrs)
        end

      # Fallback — no account ID available
      true ->
        case CalendarIntegrationQueries.get_by_user_and_provider(user_id, "google") do
          {:ok, _existing} ->
            # User already has Google integration(s) but we can't identify which account
            # this callback belongs to. Reject to avoid silently overwriting.
            {:error,
             "Could not identify your Google account. Please try again. If the problem persists, remove and re-add the integration."}

          {:error, :not_found} ->
            create_new_google_integration(user_id, nil, token_attrs)
        end
    end
  end

  defp create_new_google_integration(user_id, provider_account_id, token_attrs) do
    attrs =
      Map.merge(token_attrs, %{
        user_id: user_id,
        name: "Google Calendar",
        provider: "google",
        base_url: "https://www.googleapis.com/calendar/v3",
        is_active: true
      })

    create_fn = fn -> CalendarIntegrationQueries.create_with_auto_primary(attrs) end

    result =
      if is_binary(provider_account_id) do
        reactivation_attrs = Map.put(token_attrs, :is_active, true)

        AccountMatch.find_or_create_with_reactivation(
          fn ->
            CalendarIntegrationQueries.get_any_by_account_for_user(
              user_id,
              "google",
              provider_account_id
            )
          end,
          fn existing ->
            update_existing_integration(existing, reactivation_attrs)
          end,
          fn ->
            AccountMatch.create_with_race_protection(
              create_fn,
              fn ->
                CalendarIntegrationQueries.get_by_account_for_user(
                  user_id,
                  "google",
                  provider_account_id
                )
              end,
              fn existing -> CalendarIntegrationQueries.update(existing, token_attrs) end
            )
          end
        )
      else
        create_fn.()
      end

    with {:ok, integration} <- result do
      if integration.calendar_list == [] do
        discover_and_configure_calendars(integration)
      else
        {:ok, integration}
      end
    end
  end

  defp update_existing_integration(existing, token_attrs) do
    with {:ok, updated} <- CalendarIntegrationQueries.update(existing, token_attrs) do
      if updated.calendar_list == [] do
        discover_and_configure_calendars(updated)
      else
        {:ok, updated}
      end
    end
  end

  defp discover_and_configure_calendars(integration) do
    CalendarPrimary.discover_and_configure_calendars(integration)
  end
end
