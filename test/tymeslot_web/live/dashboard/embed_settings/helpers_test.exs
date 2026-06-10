defmodule TymeslotWeb.Live.Dashboard.EmbedSettings.HelpersTest do
  use Tymeslot.DataCase, async: true

  @moduletag :unit
  @moduletag :security

  alias TymeslotWeb.Live.Dashboard.EmbedSettings.Helpers

  describe "embed_code/2" do
    test "generates inline embed code with sanitization" do
      assigns = %{username: "testuser", base_url: "https://tymeslot.com"}
      code = Helpers.embed_code("inline", assigns)

      assert code =~ "id=\"tymeslot-booking\""
      assert code =~ "data-username=\"testuser\""
      assert code =~ "src=\"https://tymeslot.com/embed.js\""
    end

    test "generates inline embed code with extra parameters" do
      assigns = %{
        username: "testuser",
        base_url: "https://tymeslot.com",
        locale: "de",
        theme: "2",
        primary_color: "#14B8A6"
      }

      code = Helpers.embed_code("inline", assigns)

      assert code =~ "data-locale=\"de\""
      assert code =~ "data-theme=\"2\""
      assert code =~ "data-primary-color=\"#14B8A6\""
      refute code =~ "data-duration"
    end

    test "generates popup embed code with extra parameters" do
      assigns = %{
        username: "testuser",
        base_url: "https://tymeslot.com",
        locale: "fr",
        theme: "1",
        primary_color: "#FF5733"
      }

      code = Helpers.embed_code("popup", assigns)

      # Check for presence of parameters without assuming order
      assert code =~ "TymeslotBooking.open('testuser', {"
      assert code =~ "locale: 'fr'"
      assert code =~ "primaryColor: '#FF5733'"
      assert code =~ "theme: '1'"
      refute code =~ "duration"
    end

    test "generates floating embed code with extra parameters" do
      assigns = %{
        username: "testuser",
        base_url: "https://tymeslot.com",
        locale: "en",
        theme: "2"
      }

      code = Helpers.embed_code("floating", assigns)

      assert code =~ "TymeslotBooking.initFloating('testuser', {"
      assert code =~ "locale: 'en'"
      assert code =~ "theme: '2'"
    end

    test "sanitizes malicious username in embed code" do
      assigns = %{username: "<script>alert(1)</script>", base_url: "https://tymeslot.com"}
      code = Helpers.embed_code("inline", assigns)

      assert code =~ "data-username=\"invalid-username\""
      refute code =~ "<script>alert(1)</script>"
    end

    test "invalid parameters are rejected in embed code" do
      assigns = %{
        username: "testuser",
        base_url: "https://tymeslot.com",
        theme: "invalid",
        primary_color: "not-a-color",
        locale: "too-long-locale-string"
      }

      code = Helpers.embed_code("inline", assigns)

      refute code =~ "data-theme"
      refute code =~ "data-primary-color"
      refute code =~ "data-locale"
    end

    test "generates link embed code with the booking URL" do
      assigns = %{
        username: "testuser",
        base_url: "https://tymeslot.com",
        booking_url: "https://tymeslot.com/testuser"
      }

      code = Helpers.embed_code("link", assigns)

      assert code =~ ~s(<a href="https://tymeslot.com/testuser">)
      assert code =~ "Schedule a meeting"
    end

    test "returns empty string for unknown type" do
      assert Helpers.embed_code("unknown", %{}) == ""
    end
  end

  describe "embed_code/2 — customisation knobs" do
    test "inline snippet emits data-layout=column to opt into the wide canvas" do
      # Back-compat: the server now defaults every embed to the centred
      # :default layout, because snippets predating the column layout carry no
      # data-layout and must not silently flip to column on upgrade. Column is
      # therefore opt-in — a newly generated column snippet must carry the
      # explicit data-layout="column" attribute.
      assigns = %{
        username: "testuser",
        base_url: "https://tymeslot.com",
        layout: "column",
        initial_height: "500",
        max_width: "1200"
      }

      code = Helpers.embed_code("inline", assigns)

      assert code =~ ~s(data-layout="column")
      assert code =~ ~s(data-initial-height="500")
      assert code =~ ~s(data-max-width="1200")
    end

    test "inline snippet omits layout/initial-height/max-width when not provided" do
      assigns = %{username: "testuser", base_url: "https://tymeslot.com"}

      code = Helpers.embed_code("inline", assigns)

      refute code =~ "data-layout"
      refute code =~ "data-initial-height"
      refute code =~ "data-max-width"
    end

    test "inline snippet omits data-layout for default (matches the server default)" do
      # The server now defaults embeds to the centred :default layout, so
      # "Default" needs no override — the snippet stays clean and the embed
      # renders centred, the same as a legacy snippet with no data-layout.
      assigns = %{
        username: "testuser",
        base_url: "https://tymeslot.com",
        layout: "default"
      }

      code = Helpers.embed_code("inline", assigns)

      refute code =~ "data-layout"
    end

    test "inline snippet rejects out-of-range initial-height and max-width" do
      assigns = %{
        username: "testuser",
        base_url: "https://tymeslot.com",
        initial_height: "50",
        max_width: "9999"
      }

      code = Helpers.embed_code("inline", assigns)

      refute code =~ "data-initial-height"
      refute code =~ "data-max-width"
    end

    test "inline snippet rejects non-numeric initial-height and max-width" do
      assigns = %{
        username: "testuser",
        base_url: "https://tymeslot.com",
        initial_height: "tall",
        max_width: "wide"
      }

      code = Helpers.embed_code("inline", assigns)

      refute code =~ "data-initial-height"
      refute code =~ "data-max-width"
    end

    test "popup snippet emits layout: 'column' to opt into the wide canvas" do
      # Same reasoning as inline: the server defaults embeds to centred, so
      # column is opt-in and the JS options must carry it explicitly.
      assigns = %{
        username: "testuser",
        base_url: "https://tymeslot.com",
        layout: "column",
        max_width: "1200"
      }

      code = Helpers.embed_code("popup", assigns)

      assert code =~ "layout: 'column'"
      assert code =~ "maxWidth: 1200"
    end

    test "popup snippet omits layout for default (matches the server default)" do
      assigns = %{
        username: "testuser",
        base_url: "https://tymeslot.com",
        layout: "default"
      }

      code = Helpers.embed_code("popup", assigns)

      refute code =~ "layout:"
    end

    test "popup snippet emits maxWidth as a bare number, not a string" do
      assigns = %{
        username: "testuser",
        base_url: "https://tymeslot.com",
        max_width: "900"
      }

      code = Helpers.embed_code("popup", assigns)

      assert code =~ "maxWidth: 900"
      refute code =~ "maxWidth: '900'"
    end

    test "floating snippet emits layout: 'column' to opt into the wide canvas" do
      assigns = %{
        username: "testuser",
        base_url: "https://tymeslot.com",
        layout: "column",
        max_width: "1100"
      }

      code = Helpers.embed_code("floating", assigns)

      assert code =~ "layout: 'column'"
      assert code =~ "maxWidth: 1100"
    end

    test "floating snippet omits layout for default (matches the server default)" do
      assigns = %{
        username: "testuser",
        base_url: "https://tymeslot.com",
        layout: "default"
      }

      code = Helpers.embed_code("floating", assigns)

      refute code =~ "layout:"
    end

    test "link snippet appends ?layout=column when column layout is selected" do
      assigns = %{
        booking_url: "https://tymeslot.com/testuser",
        layout: "column"
      }

      code = Helpers.embed_code("link", assigns)

      assert code =~ ~s(href="https://tymeslot.com/testuser?layout=column")
    end

    test "link snippet adds no query string for the default layout" do
      assigns = %{
        booking_url: "https://tymeslot.com/testuser",
        layout: "default"
      }

      code = Helpers.embed_code("link", assigns)

      assert code =~ ~s(href="https://tymeslot.com/testuser")
      refute code =~ "?layout"
    end

    test "invalid layout values are silently dropped" do
      assigns = %{
        username: "testuser",
        base_url: "https://tymeslot.com",
        layout: "mosaic"
      }

      code = Helpers.embed_code("inline", assigns)

      refute code =~ "data-layout"
    end
  end
end
