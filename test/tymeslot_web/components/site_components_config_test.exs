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
    :feature_pages,
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

  describe "navigation/1 features menu" do
    setup do
      put_config(show_marketing_links: true, features_url: "/features")
      :ok
    end

    test "renders a plain Features link when no feature pages are configured" do
      put_config(feature_pages: [])

      html = render_component(&SiteComponents.navigation/1, current_user: nil)

      assert html =~ "Features"
      refute html =~ "All features"
    end

    test "renders a Features dropdown listing each feature page" do
      put_config(
        feature_pages: [
          %{label: "Calendar Sync", url: "/features/calendar-sync", icon: "hero-calendar"},
          %{label: "Payments", url: "/features/payments", icon: "hero-credit-card"}
        ]
      )

      html = render_component(&SiteComponents.navigation/1, current_user: nil)

      assert html =~ "All features"
      assert html =~ "Calendar Sync"
      assert html =~ ~s(href="/features/calendar-sync")
      assert html =~ "Payments"
      assert html =~ ~s(href="/features/payments")
    end

    test "hides the Features entry entirely when marketing links are disabled" do
      put_config(show_marketing_links: false, feature_pages: [])

      html = render_component(&SiteComponents.navigation/1, current_user: nil)

      refute html =~ "Features"
    end
  end
end
