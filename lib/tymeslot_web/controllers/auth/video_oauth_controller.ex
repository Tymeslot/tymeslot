defmodule TymeslotWeb.VideoOAuthController do
  @moduledoc """
  Handles OAuth authentication flows for video integrations (Google Meet, Microsoft Teams).
  """

  use TymeslotWeb, :controller
  require Logger

  alias Tymeslot.Dashboard.DashboardContext
  alias Tymeslot.Integrations.Common.OAuth.State
  alias Tymeslot.Integrations.Google.GoogleOAuthHelper
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.Teams.TeamsOAuthHelper
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Endpoint
  alias TymeslotWeb.Helpers.ClientIP

  @doc """
  Handles Google Meet OAuth callback.
  """
  @spec google_callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def google_callback(conn, %{"code" => code, "state" => state}) do
    redirect_uri = "#{Endpoint.url()}/auth/google/video/callback"

    with :ok <- RateLimiter.check_oauth_callback_rate_limit(ClientIP.get(conn)),
         :ok <- validate_state_parameter(state, google_state_secret()),
         {:ok, tokens} <- GoogleOAuthHelper.exchange_code_for_tokens(code, redirect_uri, state),
         {:ok, _integration} <-
           create_or_update_google_meet_integration(tokens, tokens[:integration_id]) do
      DashboardContext.invalidate_integration_status(tokens.user_id)

      conn
      |> put_flash(:info, "Google Meet connected successfully!")
      |> redirect(to: ~p"/dashboard/video")
    else
      {:error, :rate_limited, message} ->
        Logger.warning("Rate limit exceeded for Google Meet OAuth callback")

        conn
        |> put_flash(:error, message)
        |> redirect(to: ~p"/dashboard/video")

      {:error, :invalid_state, _reason} ->
        Logger.warning("Invalid state parameter in Google Meet OAuth callback")

        conn
        |> put_flash(:error, "Invalid authentication state. Please try again.")
        |> redirect(to: ~p"/dashboard/video")

      {:error, reason} ->
        Logger.error("Google Meet OAuth flow failed", reason: inspect(reason))

        conn
        |> put_flash(:error, "Failed to connect Google Meet. Please try again.")
        |> redirect(to: ~p"/dashboard/video")
    end
  end

  def google_callback(conn, %{"error" => error}) do
    Logger.warning("Google Meet OAuth error", error: error)

    error_message =
      case error do
        "access_denied" -> "Authorization was denied. Please try again."
        _other -> "Authentication failed. Please try again."
      end

    conn
    |> put_flash(:error, error_message)
    |> redirect(to: ~p"/dashboard/video")
  end

  def google_callback(conn, params) do
    Logger.warning("Invalid Google Meet OAuth callback params", params: inspect(params))

    conn
    |> put_flash(:error, "Invalid authentication response. Please try again.")
    |> redirect(to: ~p"/dashboard/video")
  end

  @doc """
  Handles Microsoft Teams OAuth callback.
  """
  @spec teams_callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def teams_callback(conn, %{"code" => code, "state" => state}) do
    redirect_uri = "#{Endpoint.url()}/auth/teams/video/callback"

    with :ok <- RateLimiter.check_oauth_callback_rate_limit(ClientIP.get(conn)),
         :ok <- validate_state_parameter(state, teams_state_secret()),
         {:ok, tokens} <- TeamsOAuthHelper.exchange_code_for_tokens(code, redirect_uri, state),
         :ok <- validate_teams_tokens(tokens),
         {:ok, _integration} <-
           create_or_update_teams_integration(tokens, tokens[:integration_id]) do
      DashboardContext.invalidate_integration_status(tokens.user_id)

      conn
      |> put_flash(:info, "Microsoft Teams connected successfully!")
      |> redirect(to: ~p"/dashboard/video")
    else
      error -> handle_teams_oauth_error(conn, error)
    end
  end

  def teams_callback(conn, %{"error" => error} = params) do
    error_description = Map.get(params, "error_description", "")
    Logger.warning("Teams OAuth error", error: error, description: error_description)

    error_message =
      cond do
        microsoft_admin_consent_error?(error_description) ->
          "Your Microsoft organisation requires admin approval before Tymeslot can be connected. Please ask your IT administrator to grant consent for the app."

        error == "access_denied" ->
          "Authorization was denied. Please try again."

        true ->
          "Authentication failed. Please try again."
      end

    conn
    |> put_flash(:error, error_message)
    |> redirect(to: ~p"/dashboard/video")
  end

  def teams_callback(conn, params) do
    Logger.warning("Invalid Teams OAuth callback params", params: inspect(params))

    conn
    |> put_flash(:error, "Invalid authentication response. Please try again.")
    |> redirect(to: ~p"/dashboard/video")
  end

  defp handle_teams_oauth_error(conn, error) do
    message =
      case error do
        {:error, :rate_limited, msg} ->
          Logger.warning("Rate limit exceeded for Teams OAuth callback")
          msg

        {:error, :invalid_state, _reason} ->
          Logger.warning("Invalid state parameter in Teams OAuth callback")
          "Invalid authentication state. Please try again."

        {:error, :missing_teams_fields} ->
          Logger.warning("Teams OAuth callback missing required fields: tenant_id or teams_user_id")
          "Missing required Microsoft Teams information. Please try again."

        {:error, reason} ->
          Logger.error("Teams OAuth flow failed", reason: inspect(reason))
          "Failed to connect Microsoft Teams. Please try again."
      end

    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/dashboard/video")
  end

  # Microsoft returns an error_description containing an AADSTS code when a tenant's
  # user consent policy requires an IT admin to approve the app before individuals
  # can authorise it. Detecting these codes lets us show actionable guidance instead
  # of a generic "access denied" message.
  @microsoft_admin_consent_codes ~w[AADSTS65001 AADSTS90094 AADSTS90093 AADSTS90095]

  defp microsoft_admin_consent_error?(description) do
    Enum.any?(@microsoft_admin_consent_codes, &String.contains?(description, &1))
  end

  # Private functions

  defp validate_teams_tokens(tokens) do
    if tokens[:tenant_id] && tokens[:teams_user_id] do
      :ok
    else
      Logger.error("Teams OAuth tokens missing required fields: tenant_id or teams_user_id",
        has_tenant_id: not is_nil(tokens[:tenant_id]),
        has_teams_user_id: not is_nil(tokens[:teams_user_id]),
        user_id: tokens[:user_id]
      )

      {:error, :missing_teams_fields}
    end
  end

  defp validate_state_parameter(state, secret) when is_binary(state) do
    case State.validate(state, secret) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, :invalid_state, reason}
    end
  end

  defp validate_state_parameter(_arg, _secret),
    do: {:error, :invalid_state, "Missing state parameter"}

  defp google_state_secret do
    Application.get_env(:tymeslot, :google_oauth)[:state_secret] ||
      System.get_env("GOOGLE_STATE_SECRET") ||
      raise "Google OAuth state secret not configured"
  end

  defp teams_state_secret do
    Application.get_env(:tymeslot, :outlook_oauth)[:state_secret] ||
      System.get_env("OUTLOOK_STATE_SECRET") ||
      raise "Outlook OAuth state secret not configured"
  end

  defp create_or_update_google_meet_integration(tokens, integration_id) do
    token_attrs = %{
      access_token: tokens.access_token,
      refresh_token: tokens.refresh_token,
      token_expires_at: tokens.expires_at,
      oauth_scope: tokens.scope,
      is_active: true,
      provider_account_id: tokens[:provider_account_id],
      provider_account_email: tokens[:provider_account_email]
    }

    Video.match_or_create_oauth_integration(
      tokens.user_id,
      "google_meet",
      "Google Meet",
      tokens[:provider_account_id],
      integration_id,
      token_attrs
    )
  end

  defp create_or_update_teams_integration(tokens, integration_id) do
    token_attrs = %{
      access_token: tokens.access_token,
      refresh_token: tokens.refresh_token,
      token_expires_at: tokens.expires_at,
      oauth_scope: tokens.scope,
      is_active: true,
      tenant_id: tokens.tenant_id,
      teams_user_id: tokens.teams_user_id,
      provider_account_id: tokens[:provider_account_id],
      provider_account_email: tokens[:provider_account_email]
    }

    Video.match_or_create_oauth_integration(
      tokens.user_id,
      "teams",
      "Microsoft Teams",
      tokens[:provider_account_id],
      integration_id,
      token_attrs
    )
  end
end
