defmodule Tymeslot.AppSettingsLockoutTest do
  @moduledoc """
  Lockout-protection tests for `Tymeslot.AppSettings.update/1`: the guard that
  refuses any settings change which would leave no usable authentication path
  for the admins who can currently sign in. Split out of `AppSettingsTest` to
  keep each module focused and under the large-module line cap.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :infrastructure

  import Tymeslot.Factory
  import Tymeslot.AppSettingsEnvHelpers

  alias Tymeslot.AppSettings

  setup :restore_app_settings_env

  # Enables the generic OIDC provider and gives it client credentials so it
  # counts as a usable auth path. The outer setup snapshots/restores
  # :social_auth; we restore :oauth_provider here since it isn't an
  # AppSettings leaf key.
  defp enable_credentialed_oauth do
    original = Application.get_env(:tymeslot, :oauth_provider)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:tymeslot, :oauth_provider)
        value -> Application.put_env(:tymeslot, :oauth_provider, value)
      end
    end)

    Application.put_env(:tymeslot, :oauth_provider,
      client_id: "oidc-client-id",
      client_secret: "oidc-client-secret"
    )

    Application.put_env(:tymeslot, :social_auth,
      google_enabled: false,
      github_enabled: false,
      oauth_enabled: true
    )
  end

  # Enables the generic OIDC provider WITHOUT any client credentials — the
  # brick scenario: a login button that cannot complete a sign-in.
  defp enable_credentialless_oauth do
    original = Application.get_env(:tymeslot, :oauth_provider)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:tymeslot, :oauth_provider)
        value -> Application.put_env(:tymeslot, :oauth_provider, value)
      end
    end)

    Application.put_env(:tymeslot, :oauth_provider, client_id: nil, client_secret: nil)

    Application.put_env(:tymeslot, :social_auth,
      google_enabled: false,
      github_enabled: false,
      oauth_enabled: true
    )
  end

  # Lockout protection: disabling password auth while at least one admin
  # signs in with email + password would lock that admin out of their own
  # account — having OAuth configured globally does not help if their
  # personal account has no OAuth identity linked. update/1 must refuse the
  # change in that situation.
  describe "lockout protection" do
    test "refuses to disable password_auth_enabled while a password-auth admin exists" do
      # Default factory user has a password_hash → counts as using password auth.
      # Force SSO off so the guard sees no alternative auth path.
      clamp_sso_disabled()
      insert(:user, is_admin: true)

      assert {:error, :would_lock_out} =
               AppSettings.update(%{password_auth_enabled: false})

      # And the side effect did not happen — runtime value is still true.
      assert Application.get_env(:tymeslot, :password_auth_enabled) == true
    end

    test "allows disabling password_auth_enabled when no admin uses password auth" do
      # OAuth-only admin: password auth is not their sign-in path, so disabling
      # it does not lock them out.
      insert(:user, is_admin: true, password_hash: nil, google_user_id: "google-123")

      # Non-admin password users do not block the toggle.
      insert(:user, is_admin: false)

      assert {:ok, _settings} = AppSettings.update(%{password_auth_enabled: false})
      assert Application.get_env(:tymeslot, :password_auth_enabled) == false
    end

    test "allows updates to unrelated settings even with a password-auth admin" do
      insert(:user, is_admin: true)

      assert {:ok, _settings} = AppSettings.update(%{registration_enabled: false})
    end

    test "allows re-enabling password_auth_enabled from an already locked-out state" do
      # Force the system into a locked-out state without going through update/1
      # (mirrors what could happen if env vars + DB were misconfigured at boot).
      Application.put_env(:tymeslot, :password_auth_enabled, false)

      # Admin recovers via a still-valid session — re-enabling must succeed
      # even though a password-auth admin exists (re-enabling can't lock anyone
      # out; it restores their sign-in path).
      insert(:user, is_admin: true)

      assert {:ok, _settings} = AppSettings.update(%{password_auth_enabled: true})
      assert Application.get_env(:tymeslot, :password_auth_enabled) == true
    end
  end

  # SSO must only count as a usable auth path when the provider is enabled AND
  # has client credentials configured. Otherwise an admin could enable a
  # credential-less provider (a dead login button), disable password auth, and
  # brick the install with no working sign-in path.
  describe "lockout protection — SSO credential awareness" do
    test "refuses to disable password auth when the only SSO provider has no credentials" do
      # The brick scenario: OIDC toggled on, but OAUTH_CLIENT_ID/SECRET unset.
      enable_credentialless_oauth()
      Application.put_env(:tymeslot, :password_auth_enabled, true)
      insert(:user, is_admin: true)

      assert {:error, :would_lock_out} =
               AppSettings.update(%{password_auth_enabled: false})

      assert Application.get_env(:tymeslot, :password_auth_enabled) == true
    end

    test "allows disabling password auth when a credentialed SSO provider is enabled" do
      enable_credentialed_oauth()
      Application.put_env(:tymeslot, :password_auth_enabled, true)
      insert(:user, is_admin: true)

      assert {:ok, _settings} = AppSettings.update(%{password_auth_enabled: false})
      assert Application.get_env(:tymeslot, :password_auth_enabled) == false
    end

    test "refuses to disable the last credentialed SSO provider while password auth is unusable" do
      # Password auth is off, so the credentialed OIDC provider is the only
      # working path. Turning it off would lock everyone out.
      enable_credentialed_oauth()
      Application.put_env(:tymeslot, :password_auth_enabled, false)
      insert(:user, is_admin: true)

      assert {:error, :would_lock_out} =
               AppSettings.update(%{oauth_auth_enabled: false})

      social_auth = Application.get_env(:tymeslot, :social_auth, [])
      assert Keyword.get(social_auth, :oauth_enabled) == true
    end

    test "locked_states flags oauth_auth_enabled -> false when it is the only usable path" do
      enable_credentialed_oauth()
      Application.put_env(:tymeslot, :password_auth_enabled, false)
      insert(:user, is_admin: true)

      values = AppSettings.effective_values()

      assert values[:oauth_auth_enabled].locked_states == [false]
    end

    test "locked_states is empty for oauth_auth_enabled when password auth is also usable" do
      enable_credentialed_oauth()
      Application.put_env(:tymeslot, :password_auth_enabled, true)
      insert(:user, is_admin: true)

      values = AppSettings.effective_values()

      assert values[:oauth_auth_enabled].locked_states == []
    end

    test "google_auth credentials presence is read from GOOGLE_CLIENT_ID/SECRET env" do
      System.put_env("GOOGLE_CLIENT_ID", "g-id")
      System.put_env("GOOGLE_CLIENT_SECRET", "g-secret")
      on_exit(fn -> System.delete_env("GOOGLE_CLIENT_ID") end)
      on_exit(fn -> System.delete_env("GOOGLE_CLIENT_SECRET") end)

      assert AppSettings.sso_credentials_present?(:google_auth_enabled)

      System.delete_env("GOOGLE_CLIENT_SECRET")
      refute AppSettings.sso_credentials_present?(:google_auth_enabled)
    end
  end

  # The lockout guard must run against the row-locked DB state inside the
  # update transaction, not against pre-transaction Application env, and it
  # must not be bypassable via string keys or evaded by a multi-key update.
  describe "lockout protection — guard integrity" do
    test "a multi-key update disabling every auth path at once is rejected atomically" do
      # Password auth on (and an admin uses it); Google "on" but no creds.
      clamp_sso_disabled()
      Application.put_env(:tymeslot, :password_auth_enabled, true)
      insert(:user, is_admin: true)

      assert {:error, :would_lock_out} =
               AppSettings.update(%{
                 password_auth_enabled: false,
                 google_auth_enabled: false
               })

      # Nothing was committed — password auth is still on and the row has no
      # override persisted for it.
      assert Application.get_env(:tymeslot, :password_auth_enabled) == true
      assert AppSettings.get!().password_auth_enabled == nil
    end

    test "string-keyed update cannot bypass the lockout guard" do
      clamp_sso_disabled()
      Application.put_env(:tymeslot, :password_auth_enabled, true)
      insert(:user, is_admin: true)

      assert {:error, :would_lock_out} =
               AppSettings.update(%{"password_auth_enabled" => false})

      assert Application.get_env(:tymeslot, :password_auth_enabled) == true
    end

    test "string-keyed update applies normally when it does not cause lockout" do
      assert {:ok, _settings} = AppSettings.update(%{"registration_enabled" => false})
      assert Application.get_env(:tymeslot, :registration_enabled) == false
    end

    test "an unrecognised key is rejected with a changeset rather than silently applied" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               AppSettings.update(%{"not_a_real_setting" => true})

      assert changeset.errors != []
    end

    test "guard runs against the merged DB row, not pre-update Application env" do
      # DB already has password auth disabled (committed override), but the
      # live Application env still reads true. A second update toggling the
      # last SSO provider off must be evaluated against the DB row (password
      # off) and therefore be rejected — proving the guard reads merged state.
      enable_credentialed_oauth()
      insert(:user, is_admin: true)

      # Establish credentialed OIDC as the ONLY usable SSO path, persisted as DB
      # overrides. Env-only settings don't survive here: each update's
      # flush_overrides restores every non-overridden key to its boot baseline,
      # and the test environment boots with Google/GitHub credentialed and
      # enabled — so without persisting them OFF, they remain usable paths and
      # disabling OAuth would (correctly) not lock anyone out.
      {:ok, _sso} =
        AppSettings.update(%{
          google_auth_enabled: false,
          github_auth_enabled: false,
          oauth_auth_enabled: true
        })

      {:ok, _settings} = AppSettings.update(%{password_auth_enabled: false})

      assert {:error, :would_lock_out} =
               AppSettings.update(%{oauth_auth_enabled: false})
    end
  end
end
