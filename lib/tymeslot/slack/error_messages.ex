defmodule Tymeslot.Slack.ErrorMessages do
  @moduledoc """
  User-facing messages for Slack failures, for flash notifications and inline
  error banners. Reached through `Tymeslot.Slack.translate_error/1`.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  Translates a low-level Slack API error tuple or a stored
  `disabled_reason` string into a user-facing message suitable for flash
  notifications and inline error banners.

  Accepts the exact `{:error, term()}` shapes returned by
  `Tymeslot.Slack.test_integration/1`, delivery worker callbacks, and
  `Tymeslot.Slack.set_channel/2` failures.
  """
  @spec translate_error(term()) :: String.t()
  def translate_error({:error, reason}), do: translate_error(reason)
  def translate_error({:slack_error, code, _body}), do: translate_error_code(code)
  def translate_error(code) when is_binary(code), do: translate_error_code(code)

  def translate_error(:no_token),
    do:
      dgettext(
        "dashboard_automation_chat",
        "Slack credentials are missing. Reconnect to continue."
      )

  def translate_error(:no_webhook_url),
    do: dgettext("dashboard_automation_chat", "Webhook URL is missing. Add it again to continue.")

  def translate_error(reason) when reason in [:insufficient_plan, :pro_required],
    do:
      dgettext(
        "dashboard_automation_chat",
        "Your plan does not include Slack notifications. Upgrade to connect Slack."
      )

  def translate_error(:feature_access_checker_failed),
    do:
      dgettext(
        "dashboard_automation_chat",
        "Could not verify your plan right now. Please try again in a moment."
      )

  def translate_error(:feature_disabled),
    do:
      dgettext(
        "dashboard_automation_chat",
        "Slack notifications are not enabled on this deployment."
      )

  def translate_error(:oauth_unavailable),
    do:
      dgettext(
        "dashboard_automation_chat",
        "Slack app install is not available on this deployment. Use a webhook URL instead."
      )

  def translate_error(:missing_bot_token),
    do:
      dgettext(
        "dashboard_automation_chat",
        "Slack app is not configured as a bot token app. Check your Slack app settings and ensure the OAuth scopes grant a bot token."
      )

  def translate_error({:unknown_mode, _mode}),
    do: dgettext("dashboard_automation_chat", "Slack integration is misconfigured.")

  def translate_error(%Ecto.Changeset{} = changeset) do
    case changeset.errors do
      [{_field, {"workspace already connected", _opts}} | _rest] ->
        dgettext(
          "dashboard_automation_chat",
          "This Slack workspace is already connected. Disconnect the existing integration first."
        )

      [{field, {msg, _opts}} | _rest] ->
        "#{field} #{msg}"

      _other ->
        dgettext("dashboard_automation_chat", "Could not save Slack integration.")
    end
  end

  def translate_error(other), do: unknown_error(inspect(other))

  defp translate_error_code("channel_not_found"),
    do:
      dgettext(
        "dashboard_automation_chat",
        "Channel not accessible. If it's a private channel, invite the Tymeslot bot first."
      )

  defp translate_error_code(code) when code in ["token_revoked", "account_inactive"],
    do:
      dgettext(
        "dashboard_automation_chat",
        "Slack authorisation was revoked. Reconnect to continue."
      )

  defp translate_error_code("not_in_channel"),
    do:
      dgettext(
        "dashboard_automation_chat",
        "Bot is not in this channel. Either pick a public channel or invite the bot."
      )

  defp translate_error_code("ratelimited"),
    do: dgettext("dashboard_automation_chat", "Slack is rate-limiting. Try again in a minute.")

  defp translate_error_code("webhook_url_revoked"),
    do:
      dgettext(
        "dashboard_automation_chat",
        "Webhook URL was revoked in Slack. Generate a new one."
      )

  defp translate_error_code(other), do: unknown_error(other)

  defp unknown_error(detail),
    do: dgettext("dashboard_automation_chat", "Slack error: %{error}", error: detail)
end
