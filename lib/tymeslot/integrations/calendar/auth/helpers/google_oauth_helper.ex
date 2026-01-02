defmodule Tymeslot.Integrations.Calendar.Google.OAuthHelper do
  @moduledoc """
  Helper module for Google Calendar OAuth flow.

  This module provides functions to generate OAuth URLs and handle
  the OAuth callback for Google Calendar integration.
  """

  @behaviour Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour

  alias Tymeslot.DatabaseQueries.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar, as: CalendarContext
  alias Tymeslot.Integrations.CalendarPrimary
  alias Tymeslot.Integrations.Google.GoogleOAuthHelper

  @doc """
  Generates the OAuth authorization URL for Google Calendar.

  Now requests full calendar scope to support Google Meet creation.
  """
  @spec authorization_url(pos_integer(), String.t()) :: String.t()
  def authorization_url(user_id, redirect_uri) do
    GoogleOAuthHelper.authorization_url(user_id, redirect_uri, [:calendar])
  end

  @doc """
  Handles the OAuth callback and creates or updates a calendar integration.
  """
  @spec handle_callback(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def handle_callback(code, state, redirect_uri) do
    with {:ok, tokens} <- GoogleOAuthHelper.exchange_code_for_tokens(code, redirect_uri, state),
         {:ok, integration} <- create_or_update_calendar_integration(tokens.user_id, tokens) do
      {:ok, integration}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Exchanges authorization code for access and refresh tokens.
  """
  @spec exchange_code_for_tokens(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def exchange_code_for_tokens(code, redirect_uri) do
    GoogleOAuthHelper.exchange_code_for_tokens(code, redirect_uri)
  end

  # Private functions

  defp create_or_update_calendar_integration(user_id, tokens) do
    # Check if we have an existing Google Calendar integration for this user
    case CalendarIntegrationQueries.get_by_user_and_provider(user_id, "google") do
      {:error, :not_found} ->
        # No existing integration, create new one
        attrs = %{
          user_id: user_id,
          name: "Google Calendar",
          provider: "google",
          base_url: "https://www.googleapis.com/calendar/v3",
          access_token: tokens.access_token,
          refresh_token: tokens.refresh_token,
          token_expires_at: tokens.expires_at,
          oauth_scope: tokens.scope,
          is_active: true
        }

        with {:ok, integration} <- CalendarIntegrationQueries.create_with_auto_primary(attrs) do
          # Automatically discover calendars and set primary as default
          discover_and_configure_calendars(integration)
        end

      {:ok, existing_integration} ->
        # Update existing integration with new tokens and scope
        attrs = %{
          access_token: tokens.access_token,
          refresh_token: tokens.refresh_token,
          token_expires_at: tokens.expires_at,
          oauth_scope: tokens.scope
        }

        with {:ok, updated_integration} <-
               CalendarIntegrationQueries.update(existing_integration, attrs) do
          # For existing integrations, only discover if no calendars are configured
          if updated_integration.calendar_list == [] do
            discover_and_configure_calendars(updated_integration)
          else
            {:ok, updated_integration}
          end
        end
    end
  end

  defp discover_and_configure_calendars(integration) do
    case CalendarContext.discover_calendars_for_integration(integration) do
      {:ok, calendars} ->
        # Auto-select primary/default calendar based on provider rules
        CalendarPrimary.auto_select_primary_calendar(integration, calendars)

      {:error, _reason} ->
        # If discovery fails, still return the integration
        # User can manually configure calendars later
        {:ok, integration}
    end
  end
end
