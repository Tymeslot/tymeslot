defmodule TymeslotWeb.Components.SiteComponentsConfigTest do
  # async: false — these tests mutate application config (marketing links, feature
  # pages, URLs). A synchronous module runs in isolation, so no concurrent test
  # observes the overridden values.
  use TymeslotWeb.ConnCase, async: false

  @moduletag :components

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.SiteComponents

  # Config keys read by navigation/1 and site_footer/1. Snapshot and restore them
  # around every test so overrides never leak between tests or modules.
  @config_keys [
    :show_marketing_links,
    :features_url,
    :pricing_url,
    :docs_url,
    :contact_url,
    :changelog_url,
    :privacy_policy_url,
    :terms_and_conditions_url,
    :sitemap_url
  ]

  setup do
    original = Map.new(@config_keys, &{&1, Application.fetch_env(:tymeslot, &1)})

    on_exit(fn ->
      Enum.each(original, fn
        {key, {:ok, value}} -> Application.put_env(:tymeslot, key, value)
        {key, :error} -> Application.delete_env(:tymeslot, key)
      end)
    end)

    :ok
  end

  defp put_config(overrides) do
    Enum.each(overrides, fn {key, value} -> Application.put_env(:tymeslot, key, value) end)
  end

  describe "site_footer/1 link columns" do
    test "renders the Product and Legal columns when every URL is configured" do
      put_config(
        show_marketing_links: true,
        features_url: "/features",
        pricing_url: "/pricing",
        docs_url: "/docs",
        changelog_url: "/changelog",
        contact_url: "/contact",
        privacy_policy_url: "/legal/privacy-policy",
        terms_and_conditions_url: "/legal/terms-and-conditions",
        sitemap_url: "/sitemap.xml"
      )

      html = render_component(&SiteComponents.site_footer/1, %{})

      assert html =~ "Product"
      assert html =~ "Legal"

      for {label, url} <- [
            {"Features", "/features"},
            {"Pricing", "/pricing"},
            {"Docs", "/docs"},
            {"Changelog", "/changelog"},
            {"Contact", "/contact"},
            {"Privacy Policy", "/legal/privacy-policy"},
            {"Terms and Conditions", "/legal/terms-and-conditions"},
            {"Sitemap", "/sitemap.xml"}
          ] do
        assert html =~ label
        assert html =~ ~s(href="#{url}")
      end
    end

    test "omits links whose URL is unset" do
      put_config(show_marketing_links: true, features_url: "/features")
      Application.delete_env(:tymeslot, :pricing_url)
      Application.delete_env(:tymeslot, :docs_url)

      html = render_component(&SiteComponents.site_footer/1, %{})

      assert html =~ "Features"
      refute html =~ "Pricing"
      refute html =~ "Docs"
    end

    test "hides the Product and Legal columns when marketing links are disabled" do
      put_config(
        show_marketing_links: false,
        features_url: "/features",
        privacy_policy_url: "/legal/privacy-policy"
      )

      html = render_component(&SiteComponents.site_footer/1, %{})

      refute html =~ "Product"
      refute html =~ "Legal"
      refute html =~ "Privacy Policy"
    end

    test "uses a plain href for external URLs and a LiveView navigate for internal ones" do
      put_config(
        show_marketing_links: true,
        features_url: "https://docs.example.com/features",
        pricing_url: "/pricing"
      )

      html = render_component(&SiteComponents.site_footer/1, %{})

      # External link: plain anchor, no LiveView navigation attribute.
      assert html =~ ~s(href="https://docs.example.com/features")
      # Internal link: rendered via navigate, carrying the LiveView redirect marker.
      assert html =~ ~s(href="/pricing")
      assert html =~ ~s(data-phx-link="redirect")
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
