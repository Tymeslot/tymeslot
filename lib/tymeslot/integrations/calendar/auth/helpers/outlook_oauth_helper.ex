defmodule Tymeslot.Integrations.Calendar.Outlook.OAuthHelper do
  @moduledoc """
  Helper module for Outlook/Microsoft Calendar OAuth flow.

  This module provides functions to generate OAuth URLs and handle
  the OAuth callback for Microsoft Graph API integration.
  """

  @behaviour Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour

  alias Tymeslot.DatabaseQueries.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.CalendarPrimary
  alias Tymeslot.Integrations.Common.OAuth.State
  alias Tymeslot.Integrations.Common.OAuth.TokenExchange

  @calendar_scope "https://graph.microsoft.com/Calendars.ReadWrite"
  @oauth_base_url "https://login.microsoftonline.com/common/oauth2/v2.0"
  @token_url "#{@oauth_base_url}/token"

  @doc """
  Generates the OAuth authorization URL for Microsoft/Outlook Calendar.
  """
  @spec authorization_url(pos_integer(), String.t()) :: String.t()
  def authorization_url(user_id, redirect_uri) do
    state = State.generate(user_id, state_secret())

    params = %{
      client_id: outlook_client_id(),
      redirect_uri: redirect_uri,
      response_type: "code",
      scope: @calendar_scope,
      state: state,
      response_mode: "query",
      prompt: "select_account"
    }

    query_string = URI.encode_query(params)
    "#{@oauth_base_url}/authorize?" <> query_string
  end

  @doc """
  Handles the OAuth callback and creates a calendar integration.
  """
  @spec handle_callback(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def handle_callback(code, state, redirect_uri) do
    with {:ok, user_id} <- verify_state(state),
         {:ok, tokens} <- exchange_code_for_tokens(code, redirect_uri),
         {:ok, integration} <- create_calendar_integration(user_id, tokens) do
      {:ok, integration}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Exchanges authorization code for access and refresh tokens.
  """
  @spec exchange_code_for_tokens(String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def exchange_code_for_tokens(code, redirect_uri) do
    TokenExchange.exchange_code_for_tokens(
      code,
      redirect_uri,
      @token_url,
      outlook_client_id(),
      outlook_client_secret(),
      @calendar_scope
    )
  end

  # Private functions

  defp verify_state(state) when is_binary(state) do
    State.validate(state, state_secret())
  end

  defp verify_state(_), do: {:error, "Invalid state parameter"}

  defp create_calendar_integration(user_id, tokens) do
    attrs = %{
      user_id: user_id,
      name: "Outlook Calendar",
      provider: "outlook",
      base_url: "https://graph.microsoft.com/v1.0",
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
  end

  defp discover_and_configure_calendars(integration) do
    case Calendar.discover_calendars_for_integration(integration) do
      {:ok, calendars} ->
        # Auto-select primary/default calendar based on provider rules
        CalendarPrimary.auto_select_primary_calendar(integration, calendars)

      {:error, _reason} ->
        # If discovery fails, still return the integration
        # User can manually configure calendars later
        {:ok, integration}
    end
  end

  defp outlook_client_id do
    Application.get_env(:tymeslot, :outlook_oauth)[:client_id] ||
      System.get_env("OUTLOOK_CLIENT_ID") ||
      raise "Outlook Client ID not configured"
  end

  defp outlook_client_secret do
    Application.get_env(:tymeslot, :outlook_oauth)[:client_secret] ||
      System.get_env("OUTLOOK_CLIENT_SECRET") ||
      raise "Outlook Client Secret not configured"
  end

  defp state_secret do
    Application.get_env(:tymeslot, :outlook_oauth)[:state_secret] ||
      System.get_env("OUTLOOK_STATE_SECRET") ||
      raise "Outlook State Secret not configured"
  end
end
