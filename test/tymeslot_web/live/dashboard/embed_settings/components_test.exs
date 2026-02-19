defmodule TymeslotWeb.Live.Dashboard.EmbedSettings.ComponentsTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  import Phoenix.LiveViewTest
  alias TymeslotWeb.Live.Dashboard.EmbedSettings.LivePreview
  alias TymeslotWeb.Live.Dashboard.EmbedSettings.OptionsGrid
  alias TymeslotWeb.Live.Dashboard.EmbedSettings.SecuritySection

  describe "OptionsGrid component" do
    @base_grid_assigns %{
      username: "testuser",
      base_url: "https://tymeslot.com",
      booking_url: "https://tymeslot.com/testuser",
      myself: "myself"
    }

    test "renders all options" do
      assigns = Map.put(@base_grid_assigns, :selected_embed_type, "inline")

      html = render_component(&OptionsGrid.options_grid/1, assigns)
      assert html =~ "Inline Embed"
      assert html =~ "Popup Modal"
      assert html =~ "Direct Link"
      assert html =~ "Floating Button"
      assert html =~ "Recommended"
    end

    test "exactly one card carries the selection indicator at any time" do
      # The checkmark SVG path is only rendered on the selected card (:if={@selected}).
      # Regardless of which type is active, exactly one card should be marked.
      for selected_type <- ["inline", "popup", "link", "floating"] do
        assigns = Map.put(@base_grid_assigns, :selected_embed_type, selected_type)
        html = render_component(&OptionsGrid.options_grid/1, assigns)

        # "border-turquoise-500" is added to the card container only when selected
        occurrence_count = html |> String.split("border-turquoise-500") |> length()

        assert occurrence_count == 2,
               "Expected exactly one selected card for type=#{selected_type}, " <>
                 "but found #{occurrence_count - 1} occurrences of selection indicator"
      end
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
