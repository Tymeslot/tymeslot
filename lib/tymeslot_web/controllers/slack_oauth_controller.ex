defmodule TymeslotWeb.SlackOAuthController do
  @moduledoc """
  Slack OAuth v2 start / callback endpoints.

  `start/2` redirects the logged-in user to Slack's authorize page with a
  signed state token. `callback/2` verifies that state, exchanges the code
  for a bot token, and persists a pending `:slack_integration` row that the
  dashboard will surface so the user can pick a channel.
  """

  use TymeslotWeb, :controller
  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Features
  alias Tymeslot.Slack
  alias Tymeslot.Slack.OAuth
  alias TymeslotWeb.Endpoint

  @callback_path "/api/slack/oauth/callback"

  @spec start(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def start(conn, _params) do
    user_id = conn.assigns.current_user.id

    with :ok <- check_oauth_available(),
         :ok <- check_plan_access(user_id) do
      redirect(conn, external: OAuth.authorize_url(user_id, callback_url()))
    else
      {:error, reason} ->
        conn
        |> put_flash(:error, start_error_message(reason))
        |> redirect(to: ~p"/dashboard/automation")
    end
  end

  # Guards the OAuth start endpoint. Without these, a missing client id makes
  # `OAuth.authorize_url/2` raise (500), and the plan/feature gate would only
  # be enforced after the full Slack round-trip in `callback/2`.
  defp check_oauth_available do
    if Slack.oauth_mode_available?(), do: :ok, else: {:error, :oauth_unavailable}
  end

  defp check_plan_access(user_id) do
    case Features.check_access(user_id, :automations_allowed) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_error_message(:oauth_unavailable),
    do: "Slack app install is not available on this deployment. Use a webhook URL instead."

  defp start_error_message(:insufficient_plan),
    do: "Your plan does not include Slack notifications. Upgrade to connect Slack."

  defp start_error_message(_reason),
    do: "Slack connection could not be started. Please try again."

  @spec callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def callback(conn, %{"error" => error}) do
    Logger.info("Slack OAuth error returned by Slack", error: error)

    message =
      if error == "access_denied" do
        "Slack connection cancelled."
      else
        Logger.info("Slack OAuth returned unrecognised error code", error: error)
        "Slack connection could not be completed. Please try again."
      end

    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/dashboard/automation")
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    redirect_uri = callback_url()
    current_user_id = conn.assigns.current_user.id

    with {:ok, state_user_id} <- OAuth.verify_state(state),
         :ok <- verify_state_matches_current_user(state_user_id, current_user_id),
         {:ok, install} <- OAuth.exchange_code(code, redirect_uri),
         {:ok, integration} <- Slack.complete_oauth(current_user_id, install_to_attrs(install)) do
      conn
      |> put_flash(
        :info,
        dgettext("dashboard_automation_chat", "Slack connected — pick a channel to finish setup.")
      )
      |> redirect(to: ~p"/dashboard/automation?slack_pending=#{integration.id}")
    else
      {:error, :expired_state} ->
        conn
        |> put_flash(
          :error,
          dgettext("dashboard_automation_chat", "Slack connection expired. Please try again.")
        )
        |> redirect(to: ~p"/dashboard/automation")

      {:error, :invalid_state} ->
        conn
        |> put_flash(
          :error,
          dgettext("dashboard_automation_chat", "Invalid Slack callback. Please try again.")
        )
        |> redirect(to: ~p"/dashboard/automation")

      {:error, :user_mismatch} ->
        conn
        |> put_flash(
          :error,
          dgettext(
            "dashboard_automation_chat",
            "Slack callback did not match your session. Please retry."
          )
        )
        |> redirect(to: ~p"/dashboard/automation")

      {:error, reason} ->
        Logger.warning("Slack OAuth callback failed", reason: inspect(reason))

        conn
        |> put_flash(:error, Slack.translate_error(reason))
        |> redirect(to: ~p"/dashboard/automation")
    end
  end

  def callback(conn, _params) do
    conn
    |> put_flash(
      :error,
      dgettext("dashboard_automation_chat", "Invalid Slack callback. Please try again.")
    )
    |> redirect(to: ~p"/dashboard/automation")
  end

  defp verify_state_matches_current_user(state_user_id, current_user_id)
       when state_user_id == current_user_id,
       do: :ok

  defp verify_state_matches_current_user(_state_user_id, _current_user_id),
    do: {:error, :user_mismatch}

  # Map the OAuth install map onto the attrs the integration schema needs.
  # `name` defaults to the team name so the UI has something to show before
  # the user edits it.
  defp install_to_attrs(install) do
    %{
      name: install[:team_name] || "Slack",
      bot_token: install[:bot_token],
      team_id: install[:team_id],
      team_name: install[:team_name],
      authed_user_id: install[:authed_user_id],
      scope: install[:scope],
      events: Slack.default_events_for_new_integration()
    }
  end

  defp callback_url, do: "#{Endpoint.url()}#{@callback_path}"
end
