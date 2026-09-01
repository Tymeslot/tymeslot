defmodule TymeslotWeb.AdminLiveTabsTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :live
  @moduletag :infrastructure

  import Phoenix.LiveViewTest
  import Tymeslot.AdminPageHelpers

  setup :admin_conn

  describe "how the admin panel splits settings across tabs" do
    test "each tab renders only its own sections", %{conn: conn} do
      {:ok, _lv, auth} = live(conn, ~p"/admin/authentication")
      {:ok, _lv, email} = live(conn, ~p"/admin/email")
      {:ok, _lv, general} = live(conn, ~p"/admin/general")

      # Named headings still group the sections within a tab.
      assert auth =~ "Authentication"
      assert auth =~ "reCAPTCHA"
      assert email =~ "Admin alerts"
      assert email =~ "Email branding"
      assert general =~ "Payments"
      assert general =~ "Analytics"
      assert general =~ "Localisation"

      # And a tab must not leak another tab's settings onto the page.
      refute auth =~ "Email brand name"
      refute email =~ "Password authentication"
      refute general =~ "Password authentication"
    end

    test "the tab bar links every tab and marks the active one", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/email")

      for path <- ~w(/admin/authentication /admin/email /admin/general /admin/users) do
        assert html =~ ~s(href="#{path}")
      end

      # The active pill is the one carrying the selected styling.
      assert html =~ ~r/href="\/admin\/email"[^>]*class="[^"]*bg-turquoise-600/
    end
  end
end
