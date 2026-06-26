defmodule Tymeslot.AppSettingsTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :infrastructure

  import Tymeslot.Factory
  import Tymeslot.AppSettingsEnvHelpers

  alias Tymeslot.Analytics
  alias Tymeslot.AppSettings
  alias Tymeslot.Auth
  alias Tymeslot.Auth.AuthActions
  alias Tymeslot.Infrastructure.AdminAlerts.EmailNotifier
  alias Tymeslot.Infrastructure.Config, as: InfraConfig
  alias Tymeslot.Infrastructure.Security.RecaptchaHelpers

  setup :restore_app_settings_env

  describe "update/1 + load!/0" do
    test "applying a DB override flows through Application.get_env" do
      assert {:ok, _updated} = AppSettings.update(%{registration_enabled: false})

      assert Application.get_env(:tymeslot, :registration_enabled) == false
    end

    test "reset/1 restores the captured baseline" do
      Application.put_env(:tymeslot, :registration_enabled, true)
      AppSettings.load!()

      assert {:ok, _updated} = AppSettings.update(%{registration_enabled: false})
      assert Application.get_env(:tymeslot, :registration_enabled) == false

      assert {:ok, _reset} = AppSettings.reset(:registration_enabled)
      assert Application.get_env(:tymeslot, :registration_enabled) == true
    end
  end

  describe "effective_values/0" do
    test "marks a DB-overridden setting as :db" do
      {:ok, _settings} = AppSettings.update(%{registration_enabled: false})

      values = AppSettings.effective_values()

      assert values[:registration_enabled].value == false
      assert values[:registration_enabled].source == :db
    end

    test "marks an unset DB value as :config when an Application env exists" do
      Application.put_env(:tymeslot, :registration_enabled, true)
      AppSettings.load!()

      values = AppSettings.effective_values()

      assert values[:registration_enabled].source == :config
    end

    test "locked_states flags password_auth_enabled -> false when an admin signs in with password" do
      # Force SSO off so the lockout guard isn't satisfied by a parallel
      # auth path — shell env (ENABLE_GOOGLE_AUTH etc.) can leak into the
      # test BEAM and enable SSO providers at boot.
      clamp_sso_disabled()
      Application.put_env(:tymeslot, :password_auth_enabled, true)
      insert(:user, is_admin: true)

      values = AppSettings.effective_values()

      assert values[:password_auth_enabled].locked_states == [false]
    end

    test "locked_states is empty for password_auth_enabled when no admin uses password auth" do
      Application.put_env(:tymeslot, :password_auth_enabled, true)
      insert(:user, is_admin: true, password_hash: nil)

      values = AppSettings.effective_values()

      assert values[:password_auth_enabled].locked_states == []
    end

    test "locked_states is empty for password_auth_enabled when password auth is already disabled" do
      Application.put_env(:tymeslot, :password_auth_enabled, false)
      insert(:user, is_admin: true)

      values = AppSettings.effective_values()

      assert values[:password_auth_enabled].locked_states == []
    end

    test "locked_states is empty for registration_enabled" do
      insert(:user, is_admin: true)

      values = AppSettings.effective_values()

      assert values[:registration_enabled].locked_states == []
    end

    test "locked_states flags meeting_payments_enabled -> true when Stripe platform key is unset" do
      # Default dev/test fixture sets :stripity_stripe :api_key to "sk_test_fake".
      # platform_configured?/0 should reject that placeholder, so the admin
      # cannot transition the toggle from Disabled to Enabled until an operator
      # supplies real Stripe credentials in the environment.
      Application.put_env(:stripity_stripe, :api_key, "sk_test_fake")

      values = AppSettings.effective_values()

      assert values[:meeting_payments_enabled].locked_states == [true]
    end

    test "locked_states is empty for meeting_payments_enabled when Stripe platform key is configured" do
      Application.put_env(:stripity_stripe, :api_key, "sk_test_51Hxxxxxxxxxxxxxxxxxxxxxx")

      on_exit(fn ->
        # Restore the dev/test placeholder set in runtime.exs so subsequent
        # tests do not see a real-looking key leak from this one.
        Application.put_env(:stripity_stripe, :api_key, "sk_test_fake")
      end)

      values = AppSettings.effective_values()

      assert values[:meeting_payments_enabled].locked_states == []
    end
  end

  # Bridge tests: prove that toggling a setting through the admin code path
  # (AppSettings.update/1, the same call the admin LiveView makes) actually
  # changes downstream runtime behaviour. The individual read sites have
  # their own coverage via Application.put_env — these tests pin down the
  # contract that admin-side writes flow through to those read sites.
  describe "admin toggles change runtime behaviour" do
    test "disabling registration_enabled blocks Auth.register_user/3" do
      {:ok, _settings} = AppSettings.update(%{registration_enabled: false})

      assert {:error, :registration_disabled, _msg} =
               Auth.register_user(%{"email" => "new@example.com"}, %Plug.Conn{})
    end

    test "resetting registration_enabled lifts the registration block" do
      {:ok, _settings} = AppSettings.update(%{registration_enabled: false})

      assert {:error, :registration_disabled, _msg} =
               Auth.register_user(%{"email" => "new@example.com"}, %Plug.Conn{})

      {:ok, _reset} = AppSettings.reset(:registration_enabled)

      refute match?(
               {:error, :registration_disabled, _ignored},
               Auth.register_user(%{"email" => "new@example.com"}, %Plug.Conn{})
             )
    end

    test "disabling password_auth_enabled blocks password-based registration" do
      # No admin exists, so the lockout protection does not engage.
      {:ok, _settings} = AppSettings.update(%{password_auth_enabled: false})

      socket = %Phoenix.LiveView.Socket{
        assigns: %{client_ip: "127.0.0.1", user_agent: "AppSettingsTest/1.0"}
      }

      assert {:error, "Password authentication is currently disabled."} =
               AuthActions.register_user(%{"email" => "new@example.com"}, socket)
    end

    test "disabling password_auth_enabled blocks password reset requests" do
      # No admin exists, so the lockout protection does not engage.
      {:ok, _settings} = AppSettings.update(%{password_auth_enabled: false})

      socket = %Phoenix.LiveView.Socket{
        assigns: %{client_ip: "127.0.0.1", user_agent: "AppSettingsTest/1.0"}
      }

      assert {:error, "Password authentication is currently disabled."} =
               AuthActions.request_password_reset("new@example.com", socket)
    end
  end

  # End-to-end bridge tests for every admin-editable setting: prove that an
  # AppSettings.update/1 (the same call path the admin UI takes) actually
  # changes what the consuming module returns. Each test exercises the real
  # read site, not Application.env — that's what makes these bridge tests.
  describe "settings flow through to call sites" do
    test "google_auth_enabled controls any_social_auth_enabled? via the social_auth list" do
      original = Application.get_env(:tymeslot, :social_auth) || []

      on_exit(fn -> Application.put_env(:tymeslot, :social_auth, original) end)

      Application.put_env(
        :tymeslot,
        :social_auth,
        Keyword.merge(original,
          google_enabled: false,
          github_enabled: false,
          oauth_enabled: false
        )
      )

      refute InfraConfig.any_social_auth_enabled?()

      {:ok, _settings} = AppSettings.update(%{google_auth_enabled: true})

      assert InfraConfig.any_social_auth_enabled?()
    end

    test "github_auth_enabled flows through to the social_auth keyword list" do
      {:ok, _settings} = AppSettings.update(%{github_auth_enabled: true})

      social_auth = Application.get_env(:tymeslot, :social_auth, [])
      assert Keyword.get(social_auth, :github_enabled) == true
    end

    test "oauth_auth_enabled flows through to the social_auth keyword list" do
      {:ok, _settings} = AppSettings.update(%{oauth_auth_enabled: true})

      social_auth = Application.get_env(:tymeslot, :social_auth, [])
      assert Keyword.get(social_auth, :oauth_enabled) == true
    end

    test "recaptcha_signup_enabled flips RecaptchaHelpers.signup_enabled?/0" do
      {:ok, _settings} = AppSettings.update(%{recaptcha_signup_enabled: true})
      assert RecaptchaHelpers.signup_enabled?()

      {:ok, _settings} = AppSettings.update(%{recaptcha_signup_enabled: false})
      refute RecaptchaHelpers.signup_enabled?()
    end

    test "recaptcha_booking_enabled flips RecaptchaHelpers.booking_enabled?/0" do
      {:ok, _settings} = AppSettings.update(%{recaptcha_booking_enabled: true})
      assert RecaptchaHelpers.booking_enabled?()

      {:ok, _settings} = AppSettings.update(%{recaptcha_booking_enabled: false})
      refute RecaptchaHelpers.booking_enabled?()
    end

    test "booking_analytics_enabled flips Analytics.enabled?/0" do
      {:ok, _settings} = AppSettings.update(%{booking_analytics_enabled: true})
      assert Analytics.enabled?()

      {:ok, _settings} = AppSettings.update(%{booking_analytics_enabled: false})
      refute Analytics.enabled?()
    end

    test "recaptcha_signup_min_score is what RecaptchaHelpers.signup_min_score/0 returns" do
      {:ok, _settings} = AppSettings.update(%{recaptcha_signup_min_score: 0.7})
      assert RecaptchaHelpers.signup_min_score() == 0.7
    end

    test "recaptcha_booking_min_score is what RecaptchaHelpers.booking_min_score/0 returns" do
      {:ok, _settings} = AppSettings.update(%{recaptcha_booking_min_score: 0.6})
      assert RecaptchaHelpers.booking_min_score() == 0.6
    end

    test "admin_alerts_enabled false drops emails even with a valid recipient" do
      {:ok, _settings} =
        AppSettings.update(%{
          admin_alerts_enabled: false,
          admin_alert_email: "ops@example.com"
        })

      EmailNotifier.send_alert(:calendar_sync_error, %{summary: "Sync failed"})

      refute_enqueued(
        worker: Tymeslot.Workers.EmailWorker,
        args: %{"action" => "send_admin_alert"}
      )
    end

    test "admin_alerts_enabled true with admin_alert_email enqueues an email job" do
      {:ok, _settings} =
        AppSettings.update(%{
          admin_alerts_enabled: true,
          admin_alert_email: "ops@example.com"
        })

      EmailNotifier.send_alert(:calendar_sync_error, %{summary: "Sync failed"})

      assert_enqueued(
        worker: Tymeslot.Workers.EmailWorker,
        args: %{"action" => "send_admin_alert", "recipient" => "ops@example.com"}
      )
    end

    test "admin_alerts_enabled true with no admin_alert_email still drops the email" do
      # The dev shell may export ADMIN_ALERT_EMAIL, in which case runtime.exs
      # bakes that value into the AppSettings baseline at boot — and a plain
      # `Application.delete_env` here would be overwritten by the baseline
      # restoration that runs after each AppSettings.update/1. Force the
      # baseline back to "unset" for the duration of this test.
      baseline_key = {Tymeslot.AppSettings.Env, :baseline, :admin_alert_email}
      original_baseline = :persistent_term.get(baseline_key, :__missing__)
      original_value = Application.get_env(:tymeslot, :admin_alert_email)

      :persistent_term.put(baseline_key, :error)
      Application.delete_env(:tymeslot, :admin_alert_email)

      on_exit(fn ->
        if original_baseline == :__missing__ do
          :persistent_term.erase(baseline_key)
        else
          :persistent_term.put(baseline_key, original_baseline)
        end

        if is_nil(original_value) do
          Application.delete_env(:tymeslot, :admin_alert_email)
        else
          Application.put_env(:tymeslot, :admin_alert_email, original_value)
        end
      end)

      {:ok, _settings} = AppSettings.update(%{admin_alerts_enabled: true})

      EmailNotifier.send_alert(:calendar_sync_error, %{summary: "Sync failed"})

      refute_enqueued(
        worker: Tymeslot.Workers.EmailWorker,
        args: %{"action" => "send_admin_alert"}
      )
    end
  end

  # Bridge coverage for the nested-keyword projections — settings that don't
  # live at the top level of Application env (e.g. :social_auth, :recaptcha)
  # need their writes to land in the right child key so existing call sites
  # transparently pick the override up.
  describe "nested config projections" do
    test "google_auth_enabled writes into :social_auth keyword list" do
      {:ok, _settings} = AppSettings.update(%{google_auth_enabled: true})

      assert Keyword.get(Application.get_env(:tymeslot, :social_auth), :google_enabled) == true
    end

    test "recaptcha_signup_enabled writes into :recaptcha keyword list" do
      {:ok, _settings} = AppSettings.update(%{recaptcha_signup_enabled: true})

      assert Keyword.get(Application.get_env(:tymeslot, :recaptcha), :signup_enabled) == true
    end

    test "resetting recaptcha_signup_min_score restores the captured baseline" do
      # The baseline is captured once per BEAM lifetime (`:persistent_term`),
      # so clear it explicitly to force a fresh snapshot from the value we
      # plant below. Otherwise reset/1 restores whatever runtime.exs set at
      # app boot — irrelevant for this test.
      baseline_key = {Tymeslot.AppSettings.Env, :baseline, :recaptcha_signup_min_score}
      :persistent_term.erase(baseline_key)

      original_recaptcha = Application.get_env(:tymeslot, :recaptcha) || []

      on_exit(fn ->
        :persistent_term.erase(baseline_key)
        Application.put_env(:tymeslot, :recaptcha, original_recaptcha)
        AppSettings.load!()
      end)

      Application.put_env(
        :tymeslot,
        :recaptcha,
        Keyword.put(original_recaptcha, :signup_min_score, 0.4)
      )

      AppSettings.load!()

      {:ok, _settings} = AppSettings.update(%{recaptcha_signup_min_score: 0.7})

      assert Keyword.get(Application.get_env(:tymeslot, :recaptcha), :signup_min_score) == 0.7

      {:ok, _reset} = AppSettings.reset(:recaptcha_signup_min_score)

      assert Keyword.get(Application.get_env(:tymeslot, :recaptcha), :signup_min_score) == 0.4
    end

    test "admin_alert_email rejects malformed values" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               AppSettings.update(%{admin_alert_email: "not-an-email"})

      assert {"has invalid format", _meta} = changeset.errors[:admin_alert_email]
    end

    test "admin_alert_email accepts a blank string as a clear-the-override request" do
      {:ok, _settings} = AppSettings.update(%{admin_alert_email: "ops@example.com"})
      assert Application.get_env(:tymeslot, :admin_alert_email) == "ops@example.com"

      {:ok, settings} = AppSettings.update(%{admin_alert_email: ""})
      assert settings.admin_alert_email == nil
    end

    test "recaptcha min_score rejects values above 1.0" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               AppSettings.update(%{recaptcha_signup_min_score: 1.5})

      assert {_msg, _meta} = changeset.errors[:recaptcha_signup_min_score]
    end

    test "recaptcha min_score rejects negative values" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               AppSettings.update(%{recaptcha_booking_min_score: -0.1})

      assert {_msg, _meta} = changeset.errors[:recaptcha_booking_min_score]
    end
  end
end
