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

    test "the GitHub link carries the github_cta_clicked analytics event tagged with the footer" do
      html = render_component(&SiteComponents.site_footer/1, %{})

      assert html =~ ~s(data-analytics-event="github_cta_clicked")
      assert html =~ ~s(data-analytics-props="{&quot;source_page&quot;:&quot;footer&quot;}")
    end

    test "renders every configured footer link" do
      html = render_component(&SiteComponents.site_footer/1, %{})

      # The Product and Legal columns are rendered from a data-driven list, so
      # each entry should appear whenever its URL is configured. In the umbrella
      # test environment the SaaS config enables them; in standalone Core they
      # are nil and the loop simply drops them.
      for {key, label} <- [
            {:features_url, "Features"},
            {:pricing_url, "Pricing"},
            {:docs_url, "Docs"},
            {:changelog_url, "Changelog"},
            {:contact_url, "Contact"},
            {:privacy_policy_url, "Privacy Policy"},
            {:terms_and_conditions_url, "Terms and Conditions"},
            {:sitemap_url, "Sitemap"}
          ] do
        if url = Application.get_env(:tymeslot, key) do
          assert html =~ label
          assert html =~ url
        end
      end
    end
  end
end
