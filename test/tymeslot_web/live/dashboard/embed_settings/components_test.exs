defmodule TymeslotWeb.Live.Dashboard.EmbedSettings.ComponentsTest do
  @moduletag :utils
  use TymeslotWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias TymeslotWeb.Live.Dashboard.EmbedSettings.LivePreview
  alias TymeslotWeb.Live.Dashboard.EmbedSettings.OptionsGrid
  alias TymeslotWeb.Live.Dashboard.EmbedSettings.SecuritySection

  describe "OptionsGrid component" do
  @moduletag :utils
    test "renders all options" do
      assigns = %{
        selected_embed_type: "inline",
        username: "testuser",
        base_url: "https://tymeslot.com",
        booking_url: "https://tymeslot.com/testuser",
        myself: "myself"
      }

      html = render_component(&OptionsGrid.options_grid/1, assigns)
      assert html =~ "Inline Embed"
      assert html =~ "Popup Modal"
      assert html =~ "Direct Link"
      assert html =~ "Floating Button"
      assert html =~ "Recommended"
    end
  end

  describe "SecuritySection component" do
    test "renders security section" do
      assigns = %{
        allowed_domains: [],
        myself: "myself"
      }

      html = render_component(&SecuritySection.security_section/1, assigns)
      assert html =~ "Security & Domain Control"
      assert html =~ "Add Allowed Domain"
      assert html =~ "Disabled"
    end

    test "renders when restricted" do
      assigns = %{
        allowed_domains: ["example.com"],
        myself: "myself"
      }

      html = render_component(&SecuritySection.security_section/1, assigns)
      assert html =~ "Security & Domain Control"
      assert html =~ "Add Allowed Domain"
      assert html =~ "example.com"
      assert html =~ "Restricted"
    end

    test "renders when disabled with none" do
      assigns = %{
        allowed_domains: ["none"],
        myself: "myself"
      }

      html = render_component(&SecuritySection.security_section/1, assigns)
      assert html =~ "Security & Domain Control"
      assert html =~ "Disabled"
    end
  end

  describe "LivePreview component" do
    test "renders readiness warning when not ready" do
      assigns = %{
        show_preview: true,
        selected_embed_type: "inline",
        username: "testuser",
        base_url: "https://tymeslot.com",
        embed_script_url: "/embed.js",
        is_ready: false,
        error_reason: :no_calendar,
        myself: "myself"
      }

      html = render_component(&LivePreview.live_preview/1, assigns)
      assert html =~ "Link Deactivated"
      assert html =~ "The organizer hasn&#39;t connected a calendar yet."
    end

    test "renders preview container" do
      assigns = %{
        show_preview: true,
        selected_embed_type: "inline",
        username: "testuser",
        base_url: "https://tymeslot.com",
        embed_script_url: "/embed.js",
        is_ready: true,
        error_reason: nil,
        myself: "myself"
      }

      html = render_component(&LivePreview.live_preview/1, assigns)
      assert html =~ "id=\"live-preview-container\""
      assert html =~ "data-username=\"testuser\""
    end
  end
end
