defmodule Tymeslot.AppSettingsTest do
  use Tymeslot.DataCase, async: false

  @moduletag :infrastructure

  import Tymeslot.Factory

  alias Tymeslot.AppSettings
  alias Tymeslot.Auth
  alias Tymeslot.Auth.AuthActions

  setup do
    # AppSettings.load!/0 runs on application boot. The tests below toggle
    # Application env directly, so restore it after each one.
    originals =
      Map.new(AppSettings.keys(), fn key -> {key, Application.get_env(:tymeslot, key)} end)

    on_exit(fn ->
      # Clear any DB override that a test may have applied for every editable key.
      clear_attrs = Map.new(AppSettings.keys(), fn key -> {key, nil} end)
      {:ok, _settings} = AppSettings.update(clear_attrs)

      # Restore the Application env snapshot captured before the test ran.
      Enum.each(originals, fn
        {key, nil} -> Application.delete_env(:tymeslot, key)
        {key, value} -> Application.put_env(:tymeslot, key, value)
      end)
    end)

    :ok
  end

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

  # Lockout protection: disabling password auth while at least one admin
  # signs in with email + password would lock that admin out of their own
  # account — having OAuth configured globally does not help if their
  # personal account has no OAuth identity linked. update/1 must refuse the
  # change in that situation.
  describe "lockout protection" do
    test "refuses to disable password_auth_enabled while a password-auth admin exists" do
      # Default factory user has a password_hash → counts as using password auth.
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
end
