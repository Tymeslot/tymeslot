defmodule TymeslotWeb.Components.Icons.ProviderIconTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :ui

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

    test "branded providers without a vector logo resolve to their per-size WebP logos" do
      html =
        render_component(&ProviderIcon.provider_icon/1,
          provider: "zimbra",
          type: "calendar",
          size: "mini"
        )

      # mini maps to the compact icon set.
      assert html =~ ~s(src="/icons/providers/calendar/compact/zimbra.webp")
    end

    test "vector-logo providers resolve to one SVG at every size, aliases included" do
      for {provider, type, file} <- [
            {"caldav", "calendar", "calendar/caldav.svg"},
            {"outlook_calendar", "calendar", "calendar/outlook.svg"},
            {"teams", "video", "video/teams.svg"}
          ],
          size <- ~w(mini compact medium large) do
        html =
          render_component(&ProviderIcon.provider_icon/1,
            provider: provider,
            type: type,
            size: size
          )

        assert html =~ ~s(src="/icons/providers/#{file}")
      end
    end

    test "every vector logo the component points at exists on disk" do
      providers = [
        {"caldav", "calendar"},
        {"radicale", "calendar"},
        {"baikal", "calendar"},
        {"outlook", "calendar"},
        {"teams", "video"},
        {"kmeet", "video"}
      ]

      missing =
        Enum.reject(providers, fn {provider, type} ->
          html = render_component(&ProviderIcon.provider_icon/1, provider: provider, type: type)
          [_attr, src] = Regex.run(~r/src="([^"]+)"/, html)
          File.exists?(Path.join(:code.priv_dir(:tymeslot), "static" <> src))
        end)

      assert missing == []
    end

    test "Nextcloud Talk shows the neutral video icon and is named in text, not by a logo" do
      html =
        render_component(&ProviderIcon.provider_icon/1,
          provider: "nextcloud_talk",
          type: "video",
          size: "medium"
        )

      assert html =~ ~s(src="/icons/providers/video/generic.svg")
      assert html =~ ~s(alt="Nextcloud Talk icon")
      refute html =~ "nextcloud_talk.webp"
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
