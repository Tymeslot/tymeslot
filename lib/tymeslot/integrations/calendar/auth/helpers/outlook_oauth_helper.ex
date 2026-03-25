defmodule Tymeslot.Integrations.Calendar.Outlook.OAuthHelper do
  @moduledoc """
  Helper module for Outlook/Microsoft Calendar OAuth flow.

  This module provides functions to generate OAuth URLs and handle
  the OAuth callback for Microsoft Graph API integration.
  """

  @behaviour Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour

  alias Tymeslot.DatabaseQueries.CalendarIntegrationQueries
  alias Tymeslot.Integrations.CalendarPrimary
  alias Tymeslot.Integrations.Common.OAuth.AccountMatch
  alias Tymeslot.Integrations.Common.OAuth.IdToken
  alias Tymeslot.Integrations.Common.OAuth.State
  alias Tymeslot.Integrations.Common.OAuth.TokenExchange

  require Logger

  @calendar_scope "https://graph.microsoft.com/Calendars.ReadWrite https://graph.microsoft.com/User.Read offline_access openid profile email"
  @oauth_base_url "https://login.microsoftonline.com/common/oauth2/v2.0"
  @token_url "#{@oauth_base_url}/token"

  @doc """
  Generates the OAuth authorization URL for Microsoft/Outlook Calendar.
  """
  @impl Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour
  @spec authorization_url(pos_integer(), String.t(), keyword()) :: String.t()
  def authorization_url(user_id, redirect_uri, options \\ []) do
    integration_id = Keyword.get(options, :integration_id)
    login_hint = Keyword.get(options, :login_hint)
    state = State.generate(user_id, state_secret(), integration_id)

    params = %{
      client_id: outlook_client_id(),
      redirect_uri: redirect_uri,
      response_type: "code",
      scope: @calendar_scope,
      state: state,
      response_mode: "query",
      prompt: "select_account"
    }

    params = if login_hint, do: Map.put(params, :login_hint, login_hint), else: params

    query_string = URI.encode_query(params)
    "#{@oauth_base_url}/authorize?" <> query_string
  end

  @doc """
  Handles the OAuth callback and creates a calendar integration.
  """
  @impl Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour
  @spec handle_callback(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def handle_callback(code, state, redirect_uri) do
    with {:ok, %{user_id: user_id, integration_id: integration_id}} <- verify_state(state),
         {:ok, tokens} <- exchange_code_for_tokens(code, redirect_uri),
         {:ok, integration} <- create_calendar_integration(user_id, tokens, integration_id) do
      {:ok, integration}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Exchanges authorization code for access and refresh tokens.
  """
  @impl Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour
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

  @doc """
  Refreshes an access token using a refresh token.
  """
  @impl Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour
  @spec refresh_access_token(String.t(), String.t() | nil) :: {:ok, map()} | {:error, String.t()}
  def refresh_access_token(refresh_token, current_scope \\ nil) do
    TokenExchange.refresh_access_token(
      @token_url,
      %{
        refresh_token: refresh_token,
        client_id: outlook_client_id(),
        client_secret: outlook_client_secret(),
        grant_type: "refresh_token",
        scope: current_scope || @calendar_scope
      },
      fallback_refresh_token: refresh_token,
      fallback_scope: current_scope || @calendar_scope
    )
  end

  # Private functions

  defp verify_state(state) when is_binary(state) do
    State.validate(state, state_secret())
  end

  defp verify_state(_invalid), do: {:error, "Invalid state parameter"}

  defp create_calendar_integration(user_id, tokens, integration_id) do
    {provider_account_id, provider_account_email} =
      case IdToken.decode(tokens[:id_token]) do
        {:ok, claims} ->
          {claims.oid, claims.email}

        {:error, reason} ->
          if tokens[:id_token] do
            Logger.warning(
              "Failed to decode Outlook id_token — account dedup falling back to legacy match",
              user_id: user_id,
              reason: inspect(reason)
            )
          end

          {nil, nil}
      end

    token_attrs = %{
      access_token: tokens.access_token,
      refresh_token: tokens.refresh_token,
      token_expires_at: tokens.expires_at,
      oauth_scope: tokens.scope,
      is_active: true,
      provider_account_id: provider_account_id,
      provider_account_email: provider_account_email
    }

    cond do
      # Re-authorization of specific integration
      integration_id ->
        case CalendarIntegrationQueries.get_for_user(integration_id, user_id) do
          {:ok, existing} ->
            AccountMatch.verify_account_match(existing, provider_account_id, fn ->
              update_existing_integration(existing, token_attrs)
            end)

          {:error, :not_found} ->
            {:error, "Integration not found"}
        end

      # New connection with known account
      is_binary(provider_account_id) ->
        case CalendarIntegrationQueries.get_by_account_for_user(
               user_id,
               "outlook",
               provider_account_id
             ) do
          {:ok, existing} ->
            update_existing_integration(existing, token_attrs)

          {:error, :not_found} ->
            create_new_outlook_integration(user_id, provider_account_id, token_attrs)
        end

      # Fallback — no account ID available
      true ->
        case CalendarIntegrationQueries.get_by_user_and_provider(user_id, "outlook") do
          {:ok, _existing} ->
            # User already has Outlook integration(s) but we can't identify which account
            # this callback belongs to. Reject to avoid silently overwriting.
            {:error,
             "Could not identify your Outlook account. Please try again. If the problem persists, remove and re-add the integration."}

          {:error, :not_found} ->
            create_new_outlook_integration(user_id, nil, token_attrs)
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

  defp create_new_outlook_integration(user_id, provider_account_id, token_attrs) do
    attrs =
      Map.merge(token_attrs, %{
        user_id: user_id,
        name: "Outlook Calendar",
        provider: "outlook",
        base_url: "https://graph.microsoft.com/v1.0"
      })

    create_fn = fn -> CalendarIntegrationQueries.create_with_auto_primary(attrs) end

    result =
      if is_binary(provider_account_id) do
        reactivation_attrs = Map.put(token_attrs, :is_active, true)

        AccountMatch.find_or_create_with_reactivation(
          fn ->
            CalendarIntegrationQueries.get_any_by_account_for_user(
              user_id,
              "outlook",
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
                  "outlook",
                  provider_account_id
                )
              end,
              fn existing -> update_existing_integration(existing, token_attrs) end
            )
          end
        )
      else
        create_fn.()
      end

    with {:ok, integration} <- result do
      discover_and_configure_calendars(integration)
    end
  end

  defp discover_and_configure_calendars(integration) do
    CalendarPrimary.discover_and_configure_calendars(integration)
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
