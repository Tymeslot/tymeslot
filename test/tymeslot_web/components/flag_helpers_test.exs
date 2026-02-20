defmodule TymeslotWeb.Components.FlagHelpersTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.FlagHelpers

  describe "safe_flag/1" do
    test "renders the flag SVG for a known country code" do
      html = render_component(&FlagHelpers.safe_flag/1, country_code: :usa, class: "w-6 h-4")

      assert html =~ "<svg"
      refute html =~ "🌍"
    end

    test "renders fallback icon for Algeria (:dza) which has no Flagpack flag" do
      html =
        render_component(&FlagHelpers.safe_flag/1,
          country_code: :dza,
          class: "w-6 h-4",
          fallback_icon: "🌍"
        )

      assert html =~ "🌍"
      refute html =~ "<svg"
    end

    test "renders nothing when show_fallback is false and flag is missing" do
      html =
        render_component(&FlagHelpers.safe_flag/1,
          country_code: :dza,
          class: "w-6 h-4",
          show_fallback: false
        )

      refute html =~ "🌍"
      refute html =~ "<svg"
    end

    test "renders fallback for nil country code" do
      html =
        render_component(&FlagHelpers.safe_flag/1,
          country_code: nil,
          class: "w-6 h-4",
          fallback_icon: "🌍"
        )

      assert html =~ "🌍"
    end
  end

  describe "timezone_flag/1" do
    test "renders flag for a timezone with a known flag" do
      html = render_component(&FlagHelpers.timezone_flag/1, timezone: "America/New_York", class: "w-6 h-4")

      assert html =~ "<svg"
    end

    test "renders fallback for Africa/Algiers (Algeria has no Flagpack flag)" do
      html =
        render_component(&FlagHelpers.timezone_flag/1,
          timezone: "Africa/Algiers",
          class: "w-6 h-4",
          fallback_icon: "🌍"
        )

      assert html =~ "🌍"
      refute html =~ "<svg"
    end

    test "renders fallback for unknown timezone" do
      html =
        render_component(&FlagHelpers.timezone_flag/1,
          timezone: "Fake/Zone",
          class: "w-6 h-4",
          fallback_icon: "🌍"
        )

      assert html =~ "🌍"
    end
  end
end
