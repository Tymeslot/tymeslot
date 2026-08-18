defmodule TymeslotWeb.Components.SiteComponentsTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :ui

  import Phoenix.Component, only: [sigil_H: 2]
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

  describe "navigation - optional slots" do
    test "renders end_actions and mobile_actions content when provided" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <SiteComponents.navigation current_user={nil}>
          <:end_actions><span>DESKTOP-ACTIONS</span></:end_actions>
          <:mobile_actions><span>MOBILE-ACTIONS</span></:mobile_actions>
        </SiteComponents.navigation>
        """)

      assert html =~ "DESKTOP-ACTIONS"
      assert html =~ "MOBILE-ACTIONS"
    end

    test "renders nothing extra when the slots are omitted" do
      html = render_component(&SiteComponents.navigation/1, current_user: nil)

      refute html =~ "DESKTOP-ACTIONS"
      refute html =~ "MOBILE-ACTIONS"
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

    test "renders no link columns when none are supplied" do
      html = render_component(&SiteComponents.site_footer/1, %{})

      refute html =~ "Product"
      refute html =~ "Legal"
    end

    test "renders the caller-supplied link columns" do
      columns = [
        %{
          heading: "Product",
          links: [
            %{url: "/pricing", label: "Pricing"},
            %{url: "https://docs.example.com", label: "Docs"}
          ]
        },
        %{heading: "Legal", links: [%{url: "/legal/privacy-policy", label: "Privacy Policy"}]}
      ]

      html = render_component(&SiteComponents.site_footer/1, link_columns: columns)

      assert html =~ "Product"
      assert html =~ "Legal"
      assert html =~ "Privacy Policy"
      # Internal URL: rendered via navigate (carries the LiveView redirect marker).
      assert html =~ ~s(href="/pricing")
      assert html =~ ~s(data-phx-link="redirect")
      # External URL: plain anchor, no LiveView navigation attribute.
      assert html =~ ~s(href="https://docs.example.com")
    end
  end

  describe "navigation/1 marketing menu" do
    test "renders no marketing links when no sections are supplied" do
      html = render_component(&SiteComponents.navigation/1, current_user: nil)

      refute html =~ "Features"
      refute html =~ "Pricing"
    end

    test "renders a flat link section" do
      sections = [%{kind: :link, url: "/pricing", label: "Pricing", icon: "hero-tag"}]

      html =
        render_component(&SiteComponents.navigation/1, current_user: nil, menu_sections: sections)

      assert html =~ "Pricing"
      assert html =~ ~s(href="/pricing")
    end

    test "renders a :menu with no pages as a plain link to its landing page" do
      sections = [
        %{
          kind: :menu,
          key: "features",
          label: "Features",
          icon: "hero-sparkles",
          url: "/features",
          overview: nil,
          pages: []
        }
      ]

      html =
        render_component(&SiteComponents.navigation/1, current_user: nil, menu_sections: sections)

      assert html =~ "Features"
      assert html =~ ~s(href="/features")
      refute html =~ "All features"
    end

    test "renders a populated :menu with its overview row and each page" do
      sections = [
        %{
          kind: :menu,
          key: "features",
          label: "Features",
          icon: "hero-sparkles",
          url: "/features",
          overview: %{label: "All features", icon: "hero-squares-2x2-solid", url: "/features"},
          pages: [
            %{label: "Calendar Sync", url: "/features/calendar-sync", icon: "hero-calendar"},
            %{label: "Payments", url: "/features/payments", icon: "hero-credit-card"}
          ]
        }
      ]

      html =
        render_component(&SiteComponents.navigation/1, current_user: nil, menu_sections: sections)

      assert html =~ "All features"
      assert html =~ "Calendar Sync"
      assert html =~ ~s(href="/features/calendar-sync")
      assert html =~ "Payments"
      assert html =~ ~s(href="/features/payments")
    end

    test "keys the mobile accordion by the stable key, not the (translatable) label" do
      # A label that would slug to nothing (e.g. a non-Latin translation) must
      # not break the mobile accordion's DOM id — the section's `key` does.
      sections = [
        %{
          kind: :menu,
          key: "features",
          label: "Можливості",
          icon: "hero-sparkles",
          url: "/features",
          overview: nil,
          pages: [
            %{label: "Calendar Sync", url: "/features/calendar-sync", icon: "hero-calendar"}
          ]
        }
      ]

      html =
        render_component(&SiteComponents.navigation/1, current_user: nil, menu_sections: sections)

      assert html =~ ~s(id="mobile-nav-features")
    end
  end
end
