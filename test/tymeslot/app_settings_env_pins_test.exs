defmodule Tymeslot.AppSettingsEnvPinsTest do
  @moduledoc """
  A setting fixed by an environment variable outranks the admin settings
  page: its stored override is ignored, writes to it are refused, and
  `effective_values/0` names the variable for the admin UI.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :infrastructure

  import ExUnit.CaptureLog
  import Tymeslot.AppSettingsEnvHelpers

  alias Tymeslot.AppSettings
  alias Tymeslot.AppSettings.EnvPins
  alias Tymeslot.Auth
  alias TymeslotWeb.Helpers.ClientIP

  setup :restore_app_settings_env

  # What config/runtime.exs produces at boot when the operator sets
  # REGISTRATION_ENABLED=true, followed by the boot-time load.
  defp boot_with_registration_pinned_open do
    Application.put_env(:tymeslot, :registration_enabled, true)
    pin_setting(:registration_enabled, "REGISTRATION_ENABLED")
    AppSettings.load!()
  end

  defp register do
    Auth.register_user(%{"email" => "new@example.com"}, ClientIP.request_opts(%Plug.Conn{}))
  end

  describe "a pinned setting outranks a stored override" do
    test "REGISTRATION_ENABLED=true reopens sign-up that the admin page had closed" do
      {:ok, _settings} = AppSettings.update(%{registration_enabled: false})
      assert {:error, :registration_disabled, _msg} = register()

      boot_with_registration_pinned_open()

      refute match?({:error, :registration_disabled, _msg}, register())
    end

    test "saving an unrelated setting does not overwrite a pinned top-level setting" do
      {:ok, _settings} = AppSettings.update(%{registration_enabled: false})
      boot_with_registration_pinned_open()

      {:ok, _settings} = AppSettings.update(%{booking_analytics_enabled: true})

      assert Application.get_env(:tymeslot, :registration_enabled) == true
    end

    test "saving an unrelated setting does not overwrite a pinned nested setting" do
      {:ok, _settings} = AppSettings.update(%{google_auth_enabled: false})

      Application.put_env(:tymeslot, :social_auth,
        google_enabled: true,
        github_enabled: false,
        oauth_enabled: false
      )

      pin_setting(:google_auth_enabled, "ENABLE_GOOGLE_AUTH")

      {:ok, _settings} = AppSettings.update(%{github_auth_enabled: false})

      assert Keyword.get(Application.get_env(:tymeslot, :social_auth), :google_enabled) == true
    end
  end

  describe "update/1 on a pinned setting" do
    setup do
      pin_setting(:registration_enabled, "REGISTRATION_ENABLED")
      :ok
    end

    test "refuses a value and stores nothing" do
      assert {:error, {:pinned, :registration_enabled, "REGISTRATION_ENABLED"}} =
               AppSettings.update(%{registration_enabled: false})

      assert %{registration_enabled: nil} = AppSettings.get!()
    end

    test "refuses a string-keyed value too" do
      assert {:error, {:pinned, :registration_enabled, "REGISTRATION_ENABLED"}} =
               AppSettings.update(%{"registration_enabled" => false})
    end

    test "applies nothing when one key of a multi-key update is pinned" do
      assert {:error, {:pinned, :registration_enabled, _var}} =
               AppSettings.update(%{registration_enabled: false, booking_analytics_enabled: true})

      assert %{booking_analytics_enabled: nil} = AppSettings.get!()
    end

    test "still allows clearing a value stored before the variable was set" do
      Application.put_env(:tymeslot, :env_pinned_settings, %{})
      {:ok, _settings} = AppSettings.update(%{registration_enabled: false})
      boot_with_registration_pinned_open()

      assert {:ok, _settings} = AppSettings.reset(:registration_enabled)
      assert %{registration_enabled: nil} = AppSettings.get!()
      assert Application.get_env(:tymeslot, :registration_enabled) == true
    end
  end

  describe "effective_values/0" do
    test "a pinned setting reports the variable and its value, not the stored one" do
      {:ok, _settings} = AppSettings.update(%{registration_enabled: false})
      boot_with_registration_pinned_open()

      assert %{value: true, source: :env, env_var: "REGISTRATION_ENABLED", db_value: false} =
               AppSettings.effective_values()[:registration_enabled]
    end

    test "an unpinned setting has no variable" do
      {:ok, _settings} = AppSettings.update(%{registration_enabled: false})

      assert %{source: :db, env_var: nil} = AppSettings.effective_values()[:registration_enabled]
    end
  end

  describe "warn_pins_overriding_saved_values/0" do
    # An old `.env` still carrying ENABLE_GOOGLE_AUTH=false, on an install
    # whose admin turned Google sign-in on.
    defp boot_with_google_pinned_off do
      Application.put_env(:tymeslot, :social_auth,
        google_enabled: false,
        github_enabled: false,
        oauth_enabled: false
      )

      pin_setting(:google_auth_enabled, "ENABLE_GOOGLE_AUTH")
      AppSettings.load!()
    end

    test "names the variable, the value it fixes and the saved value it hides" do
      {:ok, _settings} = AppSettings.update(%{google_auth_enabled: true})
      boot_with_google_pinned_off()

      log = capture_log(fn -> assert :ok = AppSettings.warn_pins_overriding_saved_values() end)

      assert log =~
               "ENABLE_GOOGLE_AUTH fixes google_auth_enabled to false, overriding true saved"
    end

    test "logs nothing when the saved value agrees with the variable" do
      {:ok, _settings} = AppSettings.update(%{google_auth_enabled: false})
      boot_with_google_pinned_off()

      assert capture_log(fn -> AppSettings.warn_pins_overriding_saved_values() end) == ""
    end

    test "logs nothing for a saved value no variable fixes" do
      {:ok, _settings} = AppSettings.update(%{booking_analytics_enabled: true})

      assert capture_log(fn -> AppSettings.warn_pins_overriding_saved_values() end) == ""
    end
  end

  describe "warn_unrecognised_env_values/0" do
    setup do
      original = Application.get_env(:tymeslot, :env_unrecognised_settings)
      on_exit(fn -> Application.put_env(:tymeslot, :env_unrecognised_settings, original) end)
    end

    test "names the variable, its value and what it accepts" do
      {_pins, unrecognised} = EnvPins.from_env(%{"REGISTRATION_ENABLED" => "1"})
      Application.put_env(:tymeslot, :env_unrecognised_settings, unrecognised)

      log = capture_log(fn -> assert :ok = AppSettings.warn_unrecognised_env_values() end)

      assert log =~ ~s(REGISTRATION_ENABLED="1" is not a recognised value)
      assert log =~ "the admin settings page can still change it"
      assert log =~ "REGISTRATION_ENABLED accepts true or false"
    end

    test "logs nothing when every set variable was recognised" do
      Application.put_env(:tymeslot, :env_unrecognised_settings, [])

      assert capture_log(fn -> AppSettings.warn_unrecognised_env_values() end) == ""
    end
  end
end
