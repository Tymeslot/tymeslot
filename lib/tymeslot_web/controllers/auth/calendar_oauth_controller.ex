defmodule TymeslotWeb.CalendarOAuthController do
  @moduledoc """
  Handles OAuth authentication flows for calendar integrations (Google and Outlook).
  """

  use TymeslotWeb, :controller
  require Logger

  alias Tymeslot.Integrations.Calendar.Google.OAuthHelper, as: GoogleOAuthHelper
  alias Tymeslot.Integrations.Calendar.Outlook.OAuthHelper, as: OutlookOAuthHelper
  alias Tymeslot.Integrations.Common.OAuth.State
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Endpoint
  alias TymeslotWeb.Helpers.ClientIP
  alias TymeslotWeb.Helpers.MicrosoftOAuth
  alias TymeslotWeb.OAuthCallbackHandler

  @doc """
  Handles Google Calendar OAuth callback.
  """
  @spec google_callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def google_callback(conn, %{"code" => code, "state" => state} = params) do
    redirect_path = return_to_or_default(state)
    redirect_uri = "#{Endpoint.url()}/auth/google/calendar/callback"

    OAuthCallbackHandler.handle_callback(conn, params,
      service_name: "Google Calendar",
      exchange_fun: fn _params ->
        GoogleOAuthHelper.handle_callback(code, state, redirect_uri)
      end,
      create_fun: fn result -> {:ok, result} end,
      redirect_path: redirect_path
    )
  end

  def google_callback(conn, %{"error" => error, "state" => state}) do
    redirect_path = return_to_or_default(state)
    Logger.warning("Google Calendar OAuth error", error: error)

    error_message =
      case error do
        "access_denied" -> "Authorization was denied. Please try again."
        _other -> "Authentication failed. Please try again."
      end

    conn
    |> put_flash(:error, error_message)
    |> redirect(to: redirect_path)
  end

  def google_callback(conn, %{"error" => error}) do
    Logger.warning("Google Calendar OAuth error", error: error)

    error_message =
      case error do
        "access_denied" -> "Authorization was denied. Please try again."
        _other -> "Authentication failed. Please try again."
      end

    conn
    |> put_flash(:error, error_message)
    |> redirect(to: ~p"/dashboard/calendar-integration")
  end

  def google_callback(conn, params) do
    Logger.warning("Invalid Google Calendar OAuth callback params", params: inspect(params))

    conn
    |> put_flash(:error, "Invalid authentication response. Please try again.")
    |> redirect(to: ~p"/dashboard/calendar-integration")
  end

  @doc """
  Handles Outlook Calendar OAuth callback.
  """
  @spec outlook_callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def outlook_callback(conn, %{"code" => code, "state" => state}) do
    redirect_path = return_to_or_default(state)

    case RateLimiter.check_oauth_callback_rate_limit(ClientIP.get(conn)) do
      :ok ->
        redirect_uri = "#{Endpoint.url()}/auth/outlook/calendar/callback"

        case OutlookOAuthHelper.handle_callback(code, state, redirect_uri) do
          {:ok, _integration} ->
            conn
            |> put_flash(:info, "Outlook Calendar connected successfully!")
            |> redirect(to: redirect_path)

          {:error, reason} ->
            Logger.error("Outlook Calendar OAuth callback failed", reason: inspect(reason))

            conn
            |> put_flash(:error, "Failed to connect Outlook Calendar. Please try again.")
            |> redirect(to: redirect_path)
        end

      {:error, :rate_limited, _message} ->
        Logger.warning("Rate limit exceeded for Outlook Calendar OAuth callback")

        conn
        |> put_flash(:error, "Too many requests. Please try again later.")
        |> redirect(to: redirect_path)
    end
  end

  def outlook_callback(conn, %{"error" => error, "state" => state} = params) do
    redirect_path = return_to_or_default(state)
    error_description = Map.get(params, "error_description", "")
    Logger.warning("Outlook Calendar OAuth error", error: error, description: error_description)

    error_message =
      cond do
        MicrosoftOAuth.microsoft_admin_consent_error?(error_description) ->
          "Your Microsoft organisation requires admin approval before Tymeslot can be connected. Please ask your IT administrator to grant consent for the app."

        error == "access_denied" ->
          "Authorization was denied. Please try again."

        true ->
          "Authentication failed. Please try again."
      end

    conn
    |> put_flash(:error, error_message)
    |> redirect(to: redirect_path)
  end

  def outlook_callback(conn, %{"error" => error} = params) do
    error_description = Map.get(params, "error_description", "")
    Logger.warning("Outlook Calendar OAuth error", error: error, description: error_description)

    error_message =
      cond do
        MicrosoftOAuth.microsoft_admin_consent_error?(error_description) ->
          "Your Microsoft organisation requires admin approval before Tymeslot can be connected. Please ask your IT administrator to grant consent for the app."

        error == "access_denied" ->
          "Authorization was denied. Please try again."

        true ->
          "Authentication failed. Please try again."
      end

    conn
    |> put_flash(:error, error_message)
    |> redirect(to: ~p"/dashboard/calendar-integration")
  end

  def outlook_callback(conn, params) do
    Logger.warning("Invalid Outlook Calendar OAuth callback params", params: inspect(params))

    conn
    |> put_flash(:error, "Invalid authentication response. Please try again.")
    |> redirect(to: ~p"/dashboard/calendar-integration")
  end

  defp return_to_or_default(state) do
    State.peek_return_to(state) || ~p"/dashboard/calendar-integration"
  end
end
