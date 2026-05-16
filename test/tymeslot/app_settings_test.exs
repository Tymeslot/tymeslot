defmodule Tymeslot.AppSettingsTest do
  use Tymeslot.DataCase, async: false

  @moduletag :infrastructure

  alias Tymeslot.AppSettings
  alias Tymeslot.Auth
  alias Tymeslot.Auth.AuthActions

  setup do
    # AppSettings.load!/0 runs on application boot. The tests below toggle
    # Application env directly, so restore it after each one.
    #
    # Snapshot all editable keys plus `:social_auth` (which the lockout
    # protection consults) so on_exit is symmetric with the schema: adding a
    # fourth key in future automatically gets cleaned up here.
    snapshot_keys = [:social_auth | AppSettings.keys()]

    originals =
      Map.new(snapshot_keys, fn key -> {key, Application.get_env(:tymeslot, key)} end)

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

  # Enables the generic OAuth provider for the duration of a single test.
  # Required when a test needs to disable `password_auth_enabled`, because
  # `update/1` refuses the change otherwise.
  defp enable_oauth_for_test do
    existing = Application.get_env(:tymeslot, :social_auth, [])
    Application.put_env(:tymeslot, :social_auth, Keyword.put(existing, :oauth_enabled, true))
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
      enable_oauth_for_test()
      {:ok, _settings} = AppSettings.update(%{password_auth_enabled: false})

      socket = %Phoenix.LiveView.Socket{
        assigns: %{client_ip: "127.0.0.1", user_agent: "AppSettingsTest/1.0"}
      }

      assert {:error, "Password authentication is currently disabled."} =
               AuthActions.register_user(%{"email" => "new@example.com"}, socket)
    end

    test "disabling password_auth_enabled blocks password reset requests" do
      enable_oauth_for_test()
      {:ok, _settings} = AppSettings.update(%{password_auth_enabled: false})

      socket = %Phoenix.LiveView.Socket{
        assigns: %{client_ip: "127.0.0.1", user_agent: "AppSettingsTest/1.0"}
      }

      assert {:error, "Password authentication is currently disabled."} =
               AuthActions.request_password_reset("new@example.com", socket)
    end
  end

  # Lockout protection: disabling password auth with no OAuth fallback would
  # leave the instance with no working sign-in path, locking out every user
  # including the admin who triggered it. update/1 must refuse the change.
  describe "lockout protection" do
    test "refuses to disable password_auth_enabled when no OAuth is configured" do
      Application.put_env(:tymeslot, :social_auth,
        google_enabled: false,
        github_enabled: false,
        oauth_enabled: false
      )

      assert {:error, :would_lock_out} =
               AppSettings.update(%{password_auth_enabled: false})

      # And the side effect did not happen — runtime value is still true.
      assert Application.get_env(:tymeslot, :password_auth_enabled) == true
    end

    test "allows disabling password_auth_enabled when an OAuth provider is configured" do
      enable_oauth_for_test()

      assert {:ok, _settings} = AppSettings.update(%{password_auth_enabled: false})
      assert Application.get_env(:tymeslot, :password_auth_enabled) == false
    end

    test "allows updates to unrelated settings even with no OAuth configured" do
      Application.put_env(:tymeslot, :social_auth,
        google_enabled: false,
        github_enabled: false,
        oauth_enabled: false
      )

      assert {:ok, _settings} = AppSettings.update(%{registration_enabled: false})
    end

    test "allows re-enabling password_auth_enabled from an already locked-out state" do
      # Force the system into a locked-out state without going through update/1
      # (mirrors what could happen if env vars + DB were misconfigured at boot).
      Application.put_env(:tymeslot, :social_auth,
        google_enabled: false,
        github_enabled: false,
        oauth_enabled: false
      )

      Application.put_env(:tymeslot, :password_auth_enabled, false)

      # Admin recovers via a still-valid session — re-enabling must succeed.
      assert {:ok, _settings} = AppSettings.update(%{password_auth_enabled: true})
      assert Application.get_env(:tymeslot, :password_auth_enabled) == true
    end
  end
end
