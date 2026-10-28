defmodule TymeslotWeb.Components.FlagHelpersTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :ui

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.CoreComponents.Icons
  alias TymeslotWeb.Components.FlagHelpers

  describe "safe_flag/1" do
    test "renders the flag SVG for a known country code" do
      html = render_component(&FlagHelpers.safe_flag/1, country_code: :usa, class: "w-6 h-4")

      assert html =~ "<svg"
      refute html =~ "Flag not available"
    end

    test "renders fallback icon for Algeria (:dza) which has no Flagpack flag" do
      html =
        render_component(&FlagHelpers.safe_flag/1,
          country_code: :dza,
          class: "w-6 h-4",
          fallback_icon: "hero-globe-europe-africa"
        )

      assert html =~ "Flag not available"
      assert html =~ globe_icon()
    end

    test "renders nothing when show_fallback is false and flag is missing" do
      html =
        render_component(&FlagHelpers.safe_flag/1,
          country_code: :dza,
          class: "w-6 h-4",
          show_fallback: false
        )

      refute html =~ "Flag not available"
      refute html =~ "<svg"
    end

    test "renders the default globe fallback for nil country code" do
      html = render_component(&FlagHelpers.safe_flag/1, country_code: nil, class: "w-6 h-4")

      assert html =~ "Flag not available"
      assert html =~ globe_icon()
    end
  end

  describe "timezone_flag/1" do
    test "renders flag for a timezone with a known flag" do
      html =
        render_component(&FlagHelpers.timezone_flag/1,
          timezone: "America/New_York",
          class: "w-6 h-4"
        )

      assert html =~ "<svg"
    end

    test "renders fallback for Africa/Algiers (Algeria has no Flagpack flag)" do
      html =
        render_component(&FlagHelpers.timezone_flag/1,
          timezone: "Africa/Algiers",
          class: "w-6 h-4",
          fallback_icon: "hero-globe-europe-africa"
        )

      assert html =~ "Flag not available"
      assert html =~ globe_icon()
    end

    test "renders fallback for unknown timezone" do
      html =
        render_component(&FlagHelpers.timezone_flag/1,
          timezone: "Fake/Zone",
          class: "w-6 h-4",
          fallback_icon: "hero-globe-europe-africa"
        )

      assert html =~ "Flag not available"
    end
  end

  # The globe fallback's markup exactly as `<.icon>` draws it.
  defp globe_icon do
    render_component(&Icons.icon/1, name: "hero-globe-europe-africa", class: "w-full h-full")
  end
end
