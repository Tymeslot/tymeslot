defmodule TymeslotWeb.AdminLive.EnvPinsTest do
  @moduledoc """
  The admin settings page for a setting fixed by an environment variable:
  greyed out, names the variable, and refuses a stale click.
  """

  use TymeslotWeb.ConnCase, async: false

  @moduletag :live
  @moduletag :auth

  import Phoenix.LiveViewTest
  import Tymeslot.AdminPageHelpers
  import Tymeslot.AppSettingsEnvHelpers

  alias Tymeslot.AppSettings

  setup :restore_app_settings_env

  setup :admin_conn

  setup do
    Application.put_env(:tymeslot, :registration_enabled, true)
    pin_setting(:registration_enabled, "REGISTRATION_ENABLED")
    pin_setting(:recaptcha_signup_min_score, "RECAPTCHA_SIGNUP_MIN_SCORE")
    :ok
  end

  test "a pinned toggle is greyed out and names its variable", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/admin/settings")

    assert has_element?(lv, "#setting-pinned-registration_enabled", "REGISTRATION_ENABLED")

    for state <- ["true", "false"] do
      assert has_element?(
               lv,
               ~s|button[phx-value-key="registration_enabled"][phx-value-state="#{state}"][disabled]|
             )
    end
  end

  test "a pinned toggle's tags give the pinned reason on hover", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/admin/settings")

    assert has_element?(
             lv,
             ~s|button[phx-value-key="registration_enabled"][phx-value-state="false"][title*="REGISTRATION_ENABLED"]|
           )
  end

  test "the pinned note stays legible on a pinned setting that is off", %{conn: conn} do
    Application.put_env(:tymeslot, :registration_enabled, false)

    {:ok, lv, _html} = live(conn, ~p"/admin/settings")

    # The description dims because the setting is off...
    assert has_element?(lv, ".opacity-60 h4", "Registration enabled")
    # ...but the note explaining why it cannot be switched back on does not.
    assert has_element?(lv, "#setting-pinned-registration_enabled")
    refute has_element?(lv, ".opacity-60 #setting-pinned-registration_enabled")
  end

  test "a pinned score input is disabled", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/admin/settings")

    assert has_element?(lv, "#setting-pinned-recaptcha_signup_min_score")
    assert has_element?(lv, "#setting-input-recaptcha_signup_min_score[disabled]")
  end

  test "an unpinned setting carries no pinned note", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/admin/settings")

    refute has_element?(lv, "#setting-pinned-password_auth_enabled")
    refute has_element?(lv, "#setting-pinned-recaptcha_booking_min_score")
    refute has_element?(lv, "#setting-input-recaptcha_booking_min_score[disabled]")
  end

  test "a stale click on a pinned toggle is refused with the reason", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/admin/settings")

    html =
      render_click(lv, "set_setting", %{"key" => "registration_enabled", "state" => "false"})

    assert html =~ "Set by the REGISTRATION_ENABLED environment variable"
    assert Application.get_env(:tymeslot, :registration_enabled) == true
    assert %{registration_enabled: nil} = AppSettings.get!()
  end

  test "a stale save of a pinned score is refused with the reason", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/admin/settings")

    html =
      render_change(lv, "save_setting", %{
        "key" => "recaptcha_signup_min_score",
        "value" => "0.9"
      })

    assert html =~ "Set by the RECAPTCHA_SIGNUP_MIN_SCORE environment variable"
    assert %{recaptcha_signup_min_score: nil} = AppSettings.get!()
  end
end
