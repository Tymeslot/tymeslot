defmodule TymeslotWeb.AdminLive.Formatters do
  @moduledoc """
  Pure formatting helpers shared across the admin tabs.

  Centralised here so labels and value rendering stay consistent between the
  overview, settings, and users tabs.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @doc "Human-readable label for an `AppSettings` key."
  @spec humanise(atom()) :: String.t()
  def humanise(:registration_enabled), do: dgettext("dashboard", "Registration enabled")
  def humanise(:password_auth_enabled), do: dgettext("dashboard", "Password authentication")
  def humanise(:google_auth_enabled), do: dgettext("dashboard", "Google login")
  def humanise(:github_auth_enabled), do: dgettext("dashboard", "GitHub login")
  def humanise(:oauth_auth_enabled), do: dgettext("dashboard", "Generic OIDC login")
  def humanise(:recaptcha_signup_enabled), do: dgettext("dashboard", "reCAPTCHA on signup")
  def humanise(:recaptcha_booking_enabled), do: dgettext("dashboard", "reCAPTCHA on booking")
  def humanise(:recaptcha_signup_min_score), do: dgettext("dashboard", "Signup min score")
  def humanise(:recaptcha_booking_min_score), do: dgettext("dashboard", "Booking min score")
  def humanise(:admin_alerts_enabled), do: dgettext("dashboard", "Admin alerts")
  def humanise(:admin_alert_email), do: dgettext("dashboard", "Admin alert recipient")
  def humanise(:meeting_payments_enabled), do: dgettext("dashboard", "Meeting payments")
  def humanise(:booking_analytics_enabled), do: dgettext("dashboard", "Booking analytics")

  def humanise(key),
    do: key |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

  @doc """
  Short, human-readable description of what a setting controls. Shown
  beneath the setting name on the admin settings page.

  The recommended value is rendered separately by `recommended/1` so the
  UI can give it its own visual treatment.
  """
  @spec describe(atom()) :: String.t()
  def describe(:registration_enabled) do
    dgettext(
      "dashboard",
      "Allow new users to sign up via the public registration page. Disable for a private install where admins create accounts manually."
    )
  end

  def describe(:password_auth_enabled) do
    dgettext(
      "dashboard",
      "Allow log-in with email and password. When disabled, users can only authenticate through configured OAuth providers."
    )
  end

  def describe(:google_auth_enabled) do
    dgettext(
      "dashboard",
      "Show the \"Continue with Google\" button on login and signup. Requires GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET to be set in the environment."
    )
  end

  def describe(:github_auth_enabled) do
    dgettext(
      "dashboard",
      "Show the \"Continue with GitHub\" button on login and signup. Requires GITHUB_CLIENT_ID and GITHUB_CLIENT_SECRET to be set in the environment."
    )
  end

  def describe(:oauth_auth_enabled) do
    dgettext(
      "dashboard",
      "Enable generic OAuth 2.0 / OIDC single sign-on (Keycloak, Authentik, Lemonldap, etc.). Requires the OAUTH_* environment variables to be set."
    )
  end

  def describe(:recaptcha_signup_enabled) do
    dgettext(
      "dashboard",
      "Require a passing reCAPTCHA v3 score on the public signup form. Requires RECAPTCHA_SITE_KEY and RECAPTCHA_SECRET_KEY to be set in the environment - when keys are missing the toggle is honoured but verification is silently skipped."
    )
  end

  def describe(:recaptcha_booking_enabled) do
    dgettext(
      "dashboard",
      "Require a passing reCAPTCHA v3 score on the public booking form. Requires RECAPTCHA_SITE_KEY and RECAPTCHA_SECRET_KEY to be set in the environment - when keys are missing the toggle is honoured but verification is silently skipped."
    )
  end

  def describe(:recaptcha_signup_min_score) do
    dgettext(
      "dashboard",
      "Minimum reCAPTCHA v3 score (0.0–1.0) required to accept a signup. Lower values are more permissive; 0.3 is the default and matches Google's recommendation for forms with low abuse risk."
    )
  end

  def describe(:recaptcha_booking_min_score) do
    dgettext(
      "dashboard",
      "Minimum reCAPTCHA v3 score (0.0–1.0) required to accept a booking. Lower values are more permissive; 0.3 is the default and matches Google's recommendation for forms with low abuse risk."
    )
  end

  def describe(:admin_alerts_enabled) do
    dgettext(
      "dashboard",
      "Email operational alerts (webhook failures, integration health issues, background job errors) to the admin alert recipient. Requires a recipient address to be set below."
    )
  end

  def describe(:admin_alert_email) do
    dgettext(
      "dashboard",
      "Email address that receives admin alerts when the toggle above is enabled. Leave blank to fall back to the ADMIN_ALERT_EMAIL environment variable."
    )
  end

  def describe(:meeting_payments_enabled) do
    dgettext(
      "dashboard",
      "Let hosts on this instance take payment from bookers via Stripe Connect. Requires STRIPE_SECRET_KEY and STRIPE_CONNECT_WEBHOOK_SECRET to be set in the environment - without them the toggle stays locked."
    )
  end

  def describe(:booking_analytics_enabled) do
    dgettext(
      "dashboard",
      "Collect privacy-friendly analytics for booking pages on this instance: page views, traffic source (UTM/referrer), and conversion. Counts unique visitors with a daily-rotating, cookieless fingerprint - no raw IP is stored. Off by default; review your privacy policy before enabling."
    )
  end

  def describe(_other), do: ""

  @doc """
  The recommended value for a setting, or `nil` if there is no recommendation.
  Rendered as a separate chip beneath the description.
  """
  @spec recommended(atom()) :: term() | nil
  def recommended(:registration_enabled), do: true
  def recommended(:password_auth_enabled), do: true
  def recommended(_other), do: nil

  @doc "Human-readable label for a recommended boolean value."
  @spec recommended_label(boolean()) :: String.t()
  def recommended_label(true), do: dgettext("dashboard", "Enabled")
  def recommended_label(false), do: dgettext("dashboard", "Disabled")

  @doc """
  Categorises a setting key so the UI knows which control to render.

    * `:boolean` — two-state Enabled/Disabled toggle (existing pattern).
    * `:score` — numeric input bounded 0.0–1.0 (reCAPTCHA thresholds).
    * `:email` — text input with email validation.
  """
  @spec kind(atom()) :: :boolean | :score | :email
  def kind(:recaptcha_signup_min_score), do: :score
  def kind(:recaptcha_booking_min_score), do: :score
  def kind(:admin_alert_email), do: :email
  def kind(_other), do: :boolean

  @doc """
  Section heading a setting row belongs under. Used to group the settings
  page into Authentication / reCAPTCHA / Admin alerts blocks.
  """
  @spec section(atom()) :: :authentication | :recaptcha | :payments | :analytics | :admin_alerts
  def section(:registration_enabled), do: :authentication
  def section(:password_auth_enabled), do: :authentication
  def section(:google_auth_enabled), do: :authentication
  def section(:github_auth_enabled), do: :authentication
  def section(:oauth_auth_enabled), do: :authentication
  def section(:recaptcha_signup_enabled), do: :recaptcha
  def section(:recaptcha_booking_enabled), do: :recaptcha
  def section(:recaptcha_signup_min_score), do: :recaptcha
  def section(:recaptcha_booking_min_score), do: :recaptcha
  def section(:meeting_payments_enabled), do: :payments
  def section(:booking_analytics_enabled), do: :analytics
  def section(:admin_alerts_enabled), do: :admin_alerts
  def section(:admin_alert_email), do: :admin_alerts

  @doc "Human-readable label for a section."
  @spec section_label(atom()) :: String.t()
  def section_label(:authentication), do: dgettext("dashboard", "Authentication")
  def section_label(:recaptcha), do: dgettext("dashboard", "reCAPTCHA")
  def section_label(:payments), do: dgettext("dashboard", "Payments")
  def section_label(:analytics), do: dgettext("dashboard", "Analytics")
  def section_label(:admin_alerts), do: dgettext("dashboard", "Admin alerts")

  @doc """
  When a setting is only meaningful while another setting is enabled, this
  returns the parent setting key — otherwise `nil`. The UI greys out and
  disables the dependent control when the parent's effective value is `false`.

  Example: `admin_alert_email` is meaningless while `admin_alerts_enabled`
  is off, so the recipient input is disabled until alerts are turned on.
  """
  @spec depends_on(atom()) :: atom() | nil
  def depends_on(:admin_alert_email), do: :admin_alerts_enabled
  def depends_on(_other), do: nil

  @doc """
  Explanation shown to an admin for why a particular setting state is
  currently locked. Returns `nil` when the transition is not blocked. The
  string is used both as a tooltip on the disabled toggle and as the flash
  message when a race-conditioned write reaches `AppSettings.update/1`.
  """
  @spec lock_reason(atom(), term()) :: String.t() | nil
  def lock_reason(:password_auth_enabled, false) do
    dgettext(
      "dashboard",
      "Cannot disable password authentication while at least one admin signs in with email and password - doing so would lock them out. Demote those admins or have them switch to an OAuth login first."
    )
  end

  def lock_reason(:google_auth_enabled, false), do: sso_lock_reason()
  def lock_reason(:github_auth_enabled, false), do: sso_lock_reason()
  def lock_reason(:oauth_auth_enabled, false), do: sso_lock_reason()

  def lock_reason(:meeting_payments_enabled, true) do
    dgettext(
      "dashboard",
      "Set STRIPE_SECRET_KEY and STRIPE_CONNECT_WEBHOOK_SECRET in the environment to enable meeting payments. Without platform credentials the Stripe Connect onboarding flow cannot start."
    )
  end

  def lock_reason(_key, _state), do: nil

  defp sso_lock_reason do
    dgettext(
      "dashboard",
      "Cannot disable this login provider while it is the only working sign-in path for admins. Enable password authentication or another credentialed SSO provider first."
    )
  end
end
