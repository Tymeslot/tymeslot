defmodule TymeslotWeb.CalendarOAuthController do
  @moduledoc """
  Handles OAuth authentication flows for calendar integrations (Google and Outlook).
  """

  use TymeslotWeb, :controller
  require Logger

  alias Tymeslot.Integrations.Calendar.Google.OAuthHelper, as: GoogleOAuthHelper
  alias Tymeslot.Integrations.Calendar.Outlook.OAuthHelper, as: OutlookOAuthHelper
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Endpoint
  alias TymeslotWeb.Helpers.ClientIP
  alias TymeslotWeb.OAuthCallbackHandler

  @doc """
  Handles Google Calendar OAuth callback.
  """
  @spec google_callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def google_callback(conn, %{"code" => code, "state" => state} = params) do
    redirect_uri = "#{Endpoint.url()}/auth/google/calendar/callback"

    OAuthCallbackHandler.handle_callback(conn, params,
      service_name: "Google Calendar",
      exchange_fun: fn _params ->
        GoogleOAuthHelper.handle_callback(code, state, redirect_uri)
      end,
      create_fun: fn result -> {:ok, result} end,
      redirect_path: "/dashboard/calendar"
    )
  end

  def google_callback(conn, %{"error" => error}) do
    Logger.warning("Google Calendar OAuth error: #{error}")

    error_message =
      case error do
        "access_denied" -> "Authorization was denied. Please try again."
        _ -> "Authentication failed. Please try again."
      end

    conn
    |> put_flash(:error, error_message)
    |> redirect(to: "/dashboard/calendar")
  end

  def google_callback(conn, params) do
    Logger.warning("Invalid Google Calendar OAuth callback params: #{inspect(params)}")

    conn
    |> put_flash(:error, "Invalid authentication response. Please try again.")
    |> redirect(to: "/dashboard/calendar")
  end

  @doc """
  Handles Outlook Calendar OAuth callback.
  """
  @spec outlook_callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def outlook_callback(conn, %{"code" => code, "state" => state}) do
    case RateLimiter.check_oauth_callback_rate_limit(ClientIP.get(conn)) do
      :ok ->
        redirect_uri = "#{Endpoint.url()}/auth/outlook/calendar/callback"

        case OutlookOAuthHelper.handle_callback(code, state, redirect_uri) do
          {:ok, _integration} ->
            conn
            |> put_flash(:info, "Outlook Calendar connected successfully!")
            |> redirect(to: "/dashboard/calendar")

          {:error, reason} ->
            Logger.error("Outlook Calendar OAuth callback failed: #{inspect(reason)}")

            conn
            |> put_flash(:error, "Failed to connect Outlook Calendar. Please try again.")
            |> redirect(to: "/dashboard/calendar")
        end

      {:error, :rate_limited, _message} ->
        Logger.warning("Rate limit exceeded for Outlook Calendar OAuth callback")

        conn
        |> put_flash(:error, "Too many requests. Please try again later.")
        |> redirect(to: "/dashboard/calendar")
    end
  end

  def outlook_callback(conn, %{"error" => error}) do
    Logger.warning("Outlook Calendar OAuth error: #{error}")

    error_message =
      case error do
        "access_denied" -> "Authorization was denied. Please try again."
        _ -> "Authentication failed. Please try again."
      end

    conn
    |> put_flash(:error, error_message)
    |> redirect(to: "/dashboard/calendar")
  end

  def outlook_callback(conn, params) do
    Logger.warning("Invalid Outlook Calendar OAuth callback params: #{inspect(params)}")

    conn
    |> put_flash(:error, "Invalid authentication response. Please try again.")
    |> redirect(to: "/dashboard/calendar")
  end
end
