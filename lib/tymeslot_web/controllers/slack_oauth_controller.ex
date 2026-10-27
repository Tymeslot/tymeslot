defmodule TymeslotWeb.SlackOAuthController do
  @moduledoc """
  Slack OAuth v2 start / callback endpoints.

  `start/2` redirects the logged-in user to Slack's authorize page with a
  signed state token. `callback/2` rate-limits by client and hands the rest
  (state check, code exchange, the pending `:slack_integration` row the
  dashboard surfaces for picking a channel) to
  `Slack.complete_oauth_callback/4`.
  """

  use TymeslotWeb, :controller
  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Features
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Slack
  alias Tymeslot.Slack.OAuth
  alias TymeslotWeb.Endpoint
  alias TymeslotWeb.Helpers.ClientIP

  @callback_path "/api/slack/oauth/callback"

  @spec start(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def start(conn, _params) do
    user_id = conn.assigns.current_user.id

    with :ok <- check_oauth_available(),
         :ok <- Features.check_access(user_id, :automations_allowed) do
      redirect(conn, external: OAuth.authorize_url(user_id, callback_url()))
    else
      {:error, reason} -> flash_error(conn, Slack.translate_error(reason))
    end
  end

  # Guards the OAuth start endpoint. Without these, a missing client id makes
  # `OAuth.authorize_url/2` raise (500), and the plan/feature gate would only
  # be enforced after the full Slack round-trip in `callback/2`.
  defp check_oauth_available do
    if Slack.oauth_mode_available?(), do: :ok, else: {:error, :oauth_unavailable}
  end

  @spec callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def callback(conn, %{"error" => error}) do
    Logger.info("Slack OAuth error returned by Slack", error: error)

    message =
      if error == "access_denied" do
        dgettext("dashboard_automation_chat", "Slack connection cancelled.")
      else
        Logger.info("Slack OAuth returned unrecognised error code", error: error)

        dgettext(
          "dashboard_automation_chat",
          "Slack connection could not be completed. Please try again."
        )
      end

    flash_error(conn, message)
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    user_id = conn.assigns.current_user.id

    with :ok <- RateLimiter.check(:oauth_callback, ClientIP.get(conn)),
         {:ok, integration} <-
           Slack.complete_oauth_callback(user_id, code, state, callback_url()) do
      conn
      |> put_flash(
        :info,
        dgettext("dashboard_automation_chat", "Slack connected - pick a channel to finish setup.")
      )
      |> redirect(to: ~p"/dashboard/automation?slack_pending=#{integration.id}")
    else
      error -> flash_error(conn, callback_error_message(error))
    end
  end

  def callback(conn, _params),
    do: flash_error(conn, callback_error_message({:error, :invalid_state}))

  defp callback_error_message({:error, :rate_limited, _message}) do
    Logger.warning("Rate limit exceeded for Slack OAuth callback")
    dgettext("dashboard_automation_chat", "Too many requests. Please try again later.")
  end

  defp callback_error_message({:error, :expired_state}),
    do: dgettext("dashboard_automation_chat", "Slack connection expired. Please try again.")

  defp callback_error_message({:error, :invalid_state}),
    do: dgettext("dashboard_automation_chat", "Invalid Slack callback. Please try again.")

  defp callback_error_message({:error, :user_mismatch}),
    do:
      dgettext(
        "dashboard_automation_chat",
        "Slack callback did not match your session. Please retry."
      )

  defp callback_error_message({:error, reason}) do
    Logger.warning("Slack OAuth callback failed", reason: LogFormat.reason(reason))
    Slack.translate_error(reason)
  end

  defp flash_error(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/dashboard/automation")
  end

  defp callback_url, do: "#{Endpoint.url()}#{@callback_path}"
end
