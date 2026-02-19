defmodule TymeslotWeb.Live.Dashboard.EmbedSettings.HelpersTest do
  use Tymeslot.DataCase, async: true

  @moduletag :utils

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
end
