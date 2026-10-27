defmodule TymeslotWeb.AdminLiveSupportBoxTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :live
  @moduletag :infrastructure

  import Phoenix.LiveViewTest
  import Tymeslot.AdminPageHelpers
  import Tymeslot.AppSettingsEnvHelpers

  alias Tymeslot.AppSettings

  setup :restore_app_settings_env

  setup :admin_conn

  setup do
    {:ok, _settings} = AppSettings.update(%{admin_alerts_enabled: false, admin_alert_email: nil})
    :ok
  end

  describe "the support card on the admin panel" do
    test "asks for a star and a sponsorship on every tab", %{conn: conn} do
      for path <- [
            ~p"/admin/authentication",
            ~p"/admin/email",
            ~p"/admin/general",
            ~p"/admin/users"
          ] do
        {:ok, lv, _html} = live(conn, path)

        assert has_element?(lv, ~s{#support-star a[href="https://github.com/Tymeslot/tymeslot"]})

        assert has_element?(
                 lv,
                 ~s{#support-sponsor a[href="https://github.com/sponsors/Tymeslot"]}
               )
      end
    end

    test "sends an admin without alerts to set them up, then asks for reports once they are",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/general")

      assert has_element?(lv, "#support-report", "Turn on admin alerts")
      refute has_element?(lv, "#support-report a[href*='issues/new']")

      {:ok, lv, _html} =
        lv
        |> element("#support-report a", "Set up alerts")
        |> render_click()
        |> follow_redirect(conn, ~p"/admin/email")

      lv
      |> element(~s{button[phx-value-key="admin_alerts_enabled"][phx-value-state="true"]})
      |> render_click()

      # Enabled without a recipient, alerts still reach no one.
      assert has_element?(lv, "#support-report", "Turn on admin alerts")

      lv
      |> form("#admin-setting-form-admin_alert_email", %{value: "ops@example.com"})
      |> render_submit()

      assert has_element?(lv, "#support-report", "Report what you find")

      assert has_element?(
               lv,
               ~s{#support-report a[href="https://github.com/Tymeslot/tymeslot/issues/new"]}
             )
    end
  end
end
