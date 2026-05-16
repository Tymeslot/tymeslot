defmodule Tymeslot.Repo.Migrations.AddExtraAppSettingsColumns do
  use Ecto.Migration

  # Extends `app_settings` with admin-editable overrides for env vars that
  # previously required a redeploy: SSO toggles, reCAPTCHA toggles and
  # thresholds, and the admin-alert recipient. Every column is nullable —
  # `nil` means "no override, fall back to the application config layer".
  # Idempotent so it is safe to re-run against partially migrated databases.

  def change do
    alter table(:app_settings) do
      add_if_not_exists(:google_auth_enabled, :boolean)
      add_if_not_exists(:github_auth_enabled, :boolean)
      add_if_not_exists(:oauth_auth_enabled, :boolean)
      add_if_not_exists(:recaptcha_signup_enabled, :boolean)
      add_if_not_exists(:recaptcha_booking_enabled, :boolean)
      add_if_not_exists(:recaptcha_signup_min_score, :float)
      add_if_not_exists(:recaptcha_booking_min_score, :float)
      add_if_not_exists(:admin_alerts_enabled, :boolean)
      add_if_not_exists(:admin_alert_email, :string)
    end
  end
end
