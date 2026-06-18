defmodule TymeslotWeb.Components.SiteComponentsTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.SiteComponents

  describe "navigation - authenticated user" do
    test "shows dashboard and logout links" do
      html = render_component(&SiteComponents.navigation/1, current_user: %{id: 1})

      assert html =~ "Dashboard"
      assert html =~ "Logout"
    end

    test "hides login and signup links" do
      html = render_component(&SiteComponents.navigation/1, current_user: %{id: 1})

      refute html =~ ">Login<"
      refute html =~ "Get Started"
    end

    test "logo navigates to the dashboard" do
      html = render_component(&SiteComponents.navigation/1, current_user: %{id: 1})

      assert html =~ ~s(href="/dashboard")
    end
  end

  describe "navigation - anonymous user" do
    test "shows login and signup links" do
      html = render_component(&SiteComponents.navigation/1, current_user: nil)

      assert html =~ "Login"
      assert html =~ "Get Started"
    end

    test "hides dashboard and logout links" do
      html = render_component(&SiteComponents.navigation/1, current_user: nil)

      refute html =~ "Dashboard"
      refute html =~ "Logout"
    end

    test "provides a link to the login page" do
      html = render_component(&SiteComponents.navigation/1, current_user: nil)

      assert html =~ ~s(href="/auth/login")
    end
  end

  describe "site_footer/1" do
    test "renders copyright notice" do
      html = render_component(&SiteComponents.site_footer/1, %{})

      assert html =~ "Tymeslot"
      assert html =~ "All rights reserved"
    end

    test "renders configured marketing links" do
      html = render_component(&SiteComponents.site_footer/1, %{})

      # Marketing links appear when their URLs are configured. In the umbrella
      # test environment the SaaS config enables them; in standalone Core they are nil.
      if Application.get_env(:tymeslot, :privacy_policy_url) do
        assert html =~ "Privacy Policy"
      end

      if Application.get_env(:tymeslot, :terms_and_conditions_url) do
        assert html =~ "Terms and Conditions"
      end
    end
  end
end
