defmodule TymeslotWeb.VideoOAuthController do
  @moduledoc """
  Handles OAuth authentication flows for video integrations (Google Meet, Microsoft Teams).
  """

  use TymeslotWeb, :controller
  require Logger

  alias Tymeslot.Dashboard.DashboardContext
  alias Tymeslot.DatabaseQueries.VideoIntegrationQueries
  alias Tymeslot.Integrations.Common.OAuth.State
  alias Tymeslot.Integrations.Google.GoogleOAuthHelper
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
         :ok <- validate_state_parameter(state),
         {:ok, tokens} <- GoogleOAuthHelper.exchange_code_for_tokens(code, redirect_uri, state),
         {:ok, _integration} <- create_google_meet_integration(tokens) do
      DashboardContext.invalidate_integration_status(tokens.user_id)

      conn
      |> put_flash(:info, "Google Meet connected successfully!")
      |> redirect(to: "/dashboard/video")
    else
      {:error, :rate_limited, message} ->
        Logger.warning("Rate limit exceeded for Google Meet OAuth callback")

        conn
        |> put_flash(:error, message)
        |> redirect(to: "/dashboard/video")

      {:error, :invalid_state, _reason} ->
        Logger.warning("Invalid state parameter in Google Meet OAuth callback")

        conn
        |> put_flash(:error, "Invalid authentication state. Please try again.")
        |> redirect(to: "/dashboard/video")

      {:error, reason} ->
        Logger.error("Google Meet OAuth flow failed: #{inspect(reason)}")

        conn
        |> put_flash(:error, "Failed to connect Google Meet. Please try again.")
        |> redirect(to: "/dashboard/video")
    end
  end

  def google_callback(conn, %{"error" => error}) do
    Logger.warning("Google Meet OAuth error: #{error}")

    error_message =
      case error do
        "access_denied" -> "Authorization was denied. Please try again."
        _ -> "Authentication failed. Please try again."
      end

    conn
    |> put_flash(:error, error_message)
    |> redirect(to: "/dashboard/video")
  end

  def google_callback(conn, params) do
    Logger.warning("Invalid Google Meet OAuth callback params: #{inspect(params)}")

    conn
    |> put_flash(:error, "Invalid authentication response. Please try again.")
    |> redirect(to: "/dashboard/video")
  end

  @doc """
  Handles Microsoft Teams OAuth callback.
  """
  @spec teams_callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def teams_callback(conn, %{"code" => code, "state" => state}) do
    redirect_uri = "#{Endpoint.url()}/auth/teams/video/callback"

    with :ok <- RateLimiter.check_oauth_callback_rate_limit(ClientIP.get(conn)),
         :ok <- validate_state_parameter(state),
         {:ok, tokens} <- TeamsOAuthHelper.exchange_code_for_tokens(code, redirect_uri, state),
         {:ok, _integration} <- create_teams_integration(tokens) do
      DashboardContext.invalidate_integration_status(tokens.user_id)

      conn
      |> put_flash(:info, "Microsoft Teams connected successfully!")
      |> redirect(to: "/dashboard/video")
    else
      {:error, :rate_limited, message} ->
        Logger.warning("Rate limit exceeded for Teams OAuth callback")

        conn
        |> put_flash(:error, message)
        |> redirect(to: "/dashboard/video")

      {:error, :invalid_state, _reason} ->
        Logger.warning("Invalid state parameter in Teams OAuth callback")

        conn
        |> put_flash(:error, "Invalid authentication state. Please try again.")
        |> redirect(to: "/dashboard/video")

      {:error, reason} ->
        Logger.error("Teams OAuth flow failed: #{inspect(reason)}")

        conn
        |> put_flash(:error, "Failed to connect Microsoft Teams. Please try again.")
        |> redirect(to: "/dashboard/video")
    end
  end

  def teams_callback(conn, %{"error" => error}) do
    Logger.warning("Teams OAuth error: #{error}")

    error_message =
      case error do
        "access_denied" -> "Authorization was denied. Please try again."
        _ -> "Authentication failed. Please try again."
      end

    conn
    |> put_flash(:error, error_message)
    |> redirect(to: "/dashboard/video")
  end

  def teams_callback(conn, params) do
    Logger.warning("Invalid Teams OAuth callback params: #{inspect(params)}")

    conn
    |> put_flash(:error, "Invalid authentication response. Please try again.")
    |> redirect(to: "/dashboard/video")
  end

  # Private functions

  defp validate_state_parameter(state) when is_binary(state) do
    case State.validate(state, state_secret()) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, :invalid_state, reason}
    end
  end

  defp validate_state_parameter(_), do: {:error, :invalid_state, "Missing state parameter"}

  defp state_secret do
    Application.get_env(:tymeslot, :outlook_oauth)[:state_secret] ||
      System.get_env("OUTLOOK_STATE_SECRET") ||
      raise "OAuth state secret not configured"
  end

  defp create_google_meet_integration(tokens) do
    attrs = %{
      user_id: tokens.user_id,
      name: "Google Meet",
      provider: "google_meet",
      access_token: tokens.access_token,
      refresh_token: tokens.refresh_token,
      token_expires_at: tokens.expires_at,
      oauth_scope: tokens.scope,
      is_active: true
    }

    create_and_maybe_set_default(attrs, tokens.user_id)
  end

  defp create_teams_integration(tokens) do
    attrs = %{
      user_id: tokens.user_id,
      name: "Microsoft Teams",
      provider: "teams",
      access_token: tokens.access_token,
      refresh_token: tokens.refresh_token,
      token_expires_at: tokens.expires_at,
      oauth_scope: tokens.scope,
      is_active: true
    }

    create_and_maybe_set_default(attrs, tokens.user_id)
  end

  defp create_and_maybe_set_default(attrs, user_id) do
    case VideoIntegrationQueries.create(attrs) do
      {:ok, integration} ->
        # Set as default if it's the first video integration
        case VideoIntegrationQueries.list_all_for_user(user_id) do
          [_single_integration] ->
            # This is the only integration, set as default
            VideoIntegrationQueries.set_as_default(integration)

          _ ->
            # There are other integrations, don't set as default
            {:ok, integration}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
