defmodule TymeslotWeb.VideoOAuthController do
  @moduledoc """
  Handles OAuth authentication flows for video integrations (Google Meet, Microsoft Teams, Zoom).
  """

  use TymeslotWeb, :controller
  use Gettext, backend: TymeslotWeb.Gettext
  require Logger

  alias Tymeslot.Dashboard.DashboardContext
  alias Tymeslot.Integrations.Google.GoogleOAuthHelper
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.Teams.TeamsOAuthHelper
  alias Tymeslot.Integrations.Video.Zoom.ZoomOAuthHelper
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Endpoint
  alias TymeslotWeb.Helpers.ClientIP
  alias TymeslotWeb.Helpers.MicrosoftOAuth
  alias TymeslotWeb.Helpers.OAuthStateGuard

  @doc """
  Handles Google Meet OAuth callback.
  """
  @spec google_callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def google_callback(conn, %{"code" => code, "state" => state}) do
    redirect_uri = "#{Endpoint.url()}/auth/google/video/callback"

    with :ok <- OAuthStateGuard.enforce_user_match(conn, state, :google),
         :ok <- RateLimiter.check_oauth_callback_rate_limit(ClientIP.get(conn)),
         {:ok, tokens} <- GoogleOAuthHelper.exchange_code_for_tokens(code, redirect_uri, state),
         {:ok, _integration} <-
           create_or_update_google_meet_integration(tokens, tokens[:integration_id]) do
      DashboardContext.invalidate_integration_status(tokens.user_id)

      conn
      |> put_flash(
        :info,
        dgettext("dashboard_integrations", "Google Meet connected successfully!")
      )
      |> redirect(to: ~p"/dashboard/integrations?tab=video")
    else
      error -> handle_callback_error(conn, :google, error)
    end
  end

  def google_callback(conn, %{"error" => error}) do
    Logger.warning("Google Meet OAuth error", error: error)

    error_message =
      case error do
        "access_denied" ->
          dgettext("dashboard_integrations", "Authorization was denied. Please try again.")

        _other ->
          dgettext("dashboard_integrations", "Authentication failed. Please try again.")
      end

    conn
    |> put_flash(:error, error_message)
    |> redirect(to: ~p"/dashboard/integrations?tab=video")
  end

  def google_callback(conn, params) do
    Logger.warning("Invalid Google Meet OAuth callback params",
      params: inspect(OAuthStateGuard.redact_callback_params(params))
    )

    conn
    |> put_flash(
      :error,
      dgettext("dashboard_integrations", "Invalid authentication response. Please try again.")
    )
    |> redirect(to: ~p"/dashboard/integrations?tab=video")
  end

  @doc """
  Handles Microsoft Teams OAuth callback.
  """
  @spec teams_callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def teams_callback(conn, %{"code" => code, "state" => state}) do
    redirect_uri = "#{Endpoint.url()}/auth/teams/video/callback"

    with :ok <- OAuthStateGuard.enforce_user_match(conn, state, :outlook),
         :ok <- RateLimiter.check_oauth_callback_rate_limit(ClientIP.get(conn)),
         {:ok, tokens} <- TeamsOAuthHelper.exchange_code_for_tokens(code, redirect_uri, state),
         :ok <- validate_teams_tokens(tokens),
         {:ok, _integration} <-
           create_or_update_teams_integration(tokens, tokens[:integration_id]) do
      DashboardContext.invalidate_integration_status(tokens.user_id)

      conn
      |> put_flash(
        :info,
        dgettext("dashboard_integrations", "Microsoft Teams connected successfully!")
      )
      |> redirect(to: ~p"/dashboard/integrations?tab=video")
    else
      error -> handle_callback_error(conn, :teams, error)
    end
  end

  def teams_callback(conn, %{"error" => error} = params) do
    error_description = Map.get(params, "error_description", "")
    Logger.warning("Teams OAuth error", error: error, description: error_description)

    error_message =
      cond do
        MicrosoftOAuth.microsoft_admin_consent_error?(error_description) ->
          dgettext(
            "dashboard_integrations",
            "Your Microsoft organisation requires admin approval before Tymeslot can be connected. Please ask your IT administrator to grant consent for the app."
          )

        error == "access_denied" ->
          dgettext("dashboard_integrations", "Authorization was denied. Please try again.")

        true ->
          dgettext("dashboard_integrations", "Authentication failed. Please try again.")
      end

    conn
    |> put_flash(:error, error_message)
    |> redirect(to: ~p"/dashboard/integrations?tab=video")
  end

  def teams_callback(conn, params) do
    Logger.warning("Invalid Teams OAuth callback params",
      params: inspect(OAuthStateGuard.redact_callback_params(params))
    )

    conn
    |> put_flash(
      :error,
      dgettext("dashboard_integrations", "Invalid authentication response. Please try again.")
    )
    |> redirect(to: ~p"/dashboard/integrations?tab=video")
  end

  @doc """
  Handles Zoom OAuth callback.
  """
  @spec zoom_callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def zoom_callback(conn, %{"code" => code, "state" => state}) do
    redirect_uri = "#{Endpoint.url()}/auth/zoom/video/callback"

    with :ok <- OAuthStateGuard.enforce_user_match(conn, state, :zoom),
         :ok <- RateLimiter.check_oauth_callback_rate_limit(ClientIP.get(conn)),
         {:ok, tokens} <- ZoomOAuthHelper.exchange_code_for_tokens(code, redirect_uri, state),
         :ok <- validate_zoom_tokens(tokens),
         {:ok, _integration} <-
           create_or_update_zoom_integration(tokens, tokens[:integration_id]) do
      DashboardContext.invalidate_integration_status(tokens.user_id)

      conn
      |> put_flash(:info, dgettext("dashboard_integrations", "Zoom connected successfully!"))
      |> redirect(to: ~p"/dashboard/integrations?tab=video")
    else
      error -> handle_callback_error(conn, :zoom, error)
    end
  end

  def zoom_callback(conn, %{"error" => error} = params) do
    error_description = Map.get(params, "error_description", "")
    Logger.warning("Zoom OAuth error", error: error, description: error_description)

    error_message =
      case error do
        "access_denied" ->
          dgettext("dashboard_integrations", "Authorization was denied. Please try again.")

        _other ->
          dgettext("dashboard_integrations", "Authentication failed. Please try again.")
      end

    conn
    |> put_flash(:error, error_message)
    |> redirect(to: ~p"/dashboard/integrations?tab=video")
  end

  def zoom_callback(conn, params) do
    Logger.warning("Invalid Zoom OAuth callback params",
      params: inspect(OAuthStateGuard.redact_callback_params(params))
    )

    conn
    |> put_flash(
      :error,
      dgettext("dashboard_integrations", "Invalid authentication response. Please try again.")
    )
    |> redirect(to: ~p"/dashboard/integrations?tab=video")
  end

  # One handler for all three video providers' OAuth callback errors. The
  # provider atom threads through only the two places behaviour genuinely
  # differs: the display label used in log lines, and the provider-specific
  # "missing required field" case (Teams, Zoom). Everything else — the guard
  # rejection, the rate-limit flash, and the generic failure fallback — was
  # previously copy-pasted three times over.
  @spec handle_callback_error(Plug.Conn.t(), :google | :teams | :zoom, term()) :: Plug.Conn.t()
  defp handle_callback_error(conn, _provider, {:error, guard_reason})
       when guard_reason in [:state_user_mismatch, :unauthenticated, :invalid_state] do
    reject_callback(conn)
  end

  defp handle_callback_error(conn, provider, {:error, :rate_limited, message}) do
    Logger.warning("Rate limit exceeded for OAuth callback", provider: provider_label(provider))
    flash_and_redirect(conn, message)
  end

  defp handle_callback_error(conn, :teams, {:error, :missing_teams_fields}) do
    Logger.warning("Teams OAuth callback missing required fields: tenant_id or teams_user_id")

    flash_and_redirect(
      conn,
      dgettext(
        "dashboard_integrations",
        "Missing required Microsoft Teams information. Please try again."
      )
    )
  end

  defp handle_callback_error(conn, :zoom, {:error, :missing_zoom_account_id}) do
    Logger.warning("Zoom OAuth callback missing provider_account_id")

    flash_and_redirect(
      conn,
      dgettext(
        "dashboard_integrations",
        "Could not identify your Zoom account. Please try again."
      )
    )
  end

  defp handle_callback_error(conn, provider, {:error, reason}) do
    Logger.error("OAuth flow failed",
      provider: provider_label(provider),
      reason: inspect(reason)
    )

    flash_and_redirect(conn, generic_connect_failure_message(provider))
  end

  defp provider_label(:google), do: "Google Meet"
  defp provider_label(:teams), do: "Microsoft Teams"
  defp provider_label(:zoom), do: "Zoom"

  defp generic_connect_failure_message(:google),
    do: dgettext("dashboard_integrations", "Failed to connect Google Meet. Please try again.")

  defp generic_connect_failure_message(:teams),
    do: dgettext("dashboard_integrations", "Failed to connect Microsoft Teams. Please try again.")

  defp generic_connect_failure_message(:zoom),
    do: dgettext("dashboard_integrations", "Failed to connect Zoom. Please try again.")

  defp flash_and_redirect(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/dashboard/integrations?tab=video")
  end

  defp reject_callback(conn) do
    conn
    |> put_flash(
      :error,
      dgettext(
        "dashboard_integrations",
        "Authentication session mismatch. Please sign in and try again."
      )
    )
    |> redirect(to: ~p"/dashboard/integrations?tab=video")
    |> halt()
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

  defp validate_zoom_tokens(tokens) do
    if is_binary(tokens[:provider_account_id]) and tokens[:provider_account_id] != "" do
      :ok
    else
      {:error, :missing_zoom_account_id}
    end
  end

  # Google Meet and Zoom differed only in the two literals; Teams adds the two
  # Microsoft-specific fields. Naming that difference beats three copies of one
  # token map, where a new credential field lands in some copies and not others.
  defp create_or_update_google_meet_integration(tokens, integration_id),
    do: create_or_update_integration(tokens, integration_id, "google_meet", "Google Meet")

  defp create_or_update_zoom_integration(tokens, integration_id),
    do: create_or_update_integration(tokens, integration_id, "zoom", "Zoom")

  defp create_or_update_teams_integration(tokens, integration_id) do
    create_or_update_integration(tokens, integration_id, "teams", "Microsoft Teams", %{
      tenant_id: tokens.tenant_id,
      teams_user_id: tokens.teams_user_id
    })
  end

  defp create_or_update_integration(tokens, integration_id, slug, display_name, extra \\ %{}) do
    token_attrs =
      Map.merge(
        %{
          access_token: tokens.access_token,
          refresh_token: tokens.refresh_token,
          token_expires_at: tokens.expires_at,
          oauth_scope: tokens.scope,
          is_active: true,
          provider_account_id: tokens[:provider_account_id],
          provider_account_email: tokens[:provider_account_email]
        },
        extra
      )

    Video.match_or_create_oauth_integration(
      tokens.user_id,
      slug,
      display_name,
      tokens[:provider_account_id],
      integration_id,
      token_attrs
    )
  end
end
