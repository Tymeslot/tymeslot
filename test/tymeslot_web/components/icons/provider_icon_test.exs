defmodule TymeslotWeb.Components.Icons.ProviderIconTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.Icons.ProviderIcon

  describe "provider_icon/1" do
    test "the dev-only debug calendar renders the bundled demo SVG, not a missing PNG" do
      html =
        render_component(&ProviderIcon.provider_icon/1, provider: "debug", type: "calendar")

      # Without the demo SVG this would point at a non-existent debug.png and
      # render as a broken <img>.
      assert html =~ ~s(src="/icons/providers/calendar/debug.svg")
      refute html =~ "debug.png"
    end

    test "branded providers still resolve to their per-size WebP logos" do
      html =
        render_component(&ProviderIcon.provider_icon/1,
          provider: "caldav",
          type: "calendar",
          size: "mini"
        )

      # mini maps to the compact icon set.
      assert html =~ ~s(src="/icons/providers/calendar/compact/caldav.webp")
    end

    test "icons defer loading and reserve their box before the stylesheet lands" do
      html =
        render_component(&ProviderIcon.provider_icon/1, provider: "zoom", type: "video")

      assert html =~ ~s(loading="lazy")
      assert html =~ ~s(width="32")
      assert html =~ ~s(height="32")
    end

    test "callers rendering above the fold can opt out of lazy loading" do
      html =
        render_component(&ProviderIcon.provider_icon/1,
          provider: "zoom",
          type: "video",
          loading: "eager"
        )

      assert html =~ ~s(loading="eager")
    end
  end
end
