defmodule TymeslotWeb.Dashboard.ProfileSettings.EmailSending.ErrorMessages do
  @moduledoc """
  Translates fixed SMTP outcome categories without exposing relay responses.

  Unknown results use generic copy. Stored error codes never become user-facing
  text directly, even if a record contains an unexpected historical value.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @stored_codes %{
    "authentication_failed" => :authentication_failed,
    "tls_required" => :tls_required,
    "dns_failed" => :dns_failed,
    "invalid_destination" => :invalid_destination,
    "credentials_unavailable" => :credentials_unavailable,
    "invalid_settings" => :invalid_settings,
    "not_tested" => :not_tested,
    "session_timeout" => :session_timeout,
    "ambiguous_timeout" => :ambiguous_timeout,
    "delivery_failed" => :delivery_failed
  }

  @doc "Safe, actionable copy for a domain refusal or saved delivery failure."
  @spec message(term()) :: String.t()
  def message(code) when is_binary(code),
    do: message(Map.get(@stored_codes, code, :delivery_failed))

  def message(reason) when reason in [:stale, :invalid_version, :settings_changed, :not_found] do
    dgettext(
      "dashboard_email_sending",
      "Your email settings changed. Review the current settings and try again."
    )
  end

  def message(:authentication_failed) do
    dgettext(
      "dashboard_email_sending",
      "The SMTP server refused the credentials. Check the username and password, or use an app password."
    )
  end

  def message(:tls_required) do
    dgettext(
      "dashboard_email_sending",
      "The required TLS connection failed. Check the SMTP hostname and connection security."
    )
  end

  def message(:dns_failed),
    do:
      dgettext(
        "dashboard_email_sending",
        "The SMTP hostname could not be resolved. Check it and try again."
      )

  def message(:invalid_destination) do
    dgettext(
      "dashboard_email_sending",
      "Choose a public SMTP hostname. Private and local mail servers are not supported."
    )
  end

  def message(:credentials_unavailable) do
    dgettext(
      "dashboard_email_sending",
      "The saved credentials could not be read. Enter them again and test the connection."
    )
  end

  def message(:invalid_settings),
    do: dgettext("dashboard_email_sending", "Check the email settings and try again.")

  def message(:not_tested),
    do: dgettext("dashboard_email_sending", "Test and save these settings before enabling them.")

  def message(:session_timeout),
    do:
      dgettext(
        "dashboard_email_sending",
        "The SMTP server did not respond in time. Try again shortly."
      )

  def message(reason) when reason in [:timeout, :ambiguous_timeout] do
    dgettext(
      "dashboard_email_sending",
      "The SMTP server timed out. It may have accepted the message; check before trying again."
    )
  end

  def message(:rate_limited),
    do:
      dgettext(
        "dashboard_email_sending",
        "Too many SMTP tests or connections. Wait a few minutes and try again."
      )

  def message(:unverified_user),
    do:
      dgettext(
        "dashboard_email_sending",
        "Verify your account email before testing or enabling custom SMTP."
      )

  def message(reason) when reason in [:feature_disabled, :invalid_user] do
    dgettext(
      "dashboard_email_sending",
      "Email sending settings are unavailable. Reload the page to continue."
    )
  end

  def message(reason) when reason in [:connection_unavailable, :breaker_unavailable] do
    dgettext(
      "dashboard_email_sending",
      "Email testing is temporarily unavailable. Try again shortly."
    )
  end

  def message(_unknown),
    do:
      dgettext(
        "dashboard_email_sending",
        "The SMTP operation could not be completed. Check the settings and try again."
      )
end
