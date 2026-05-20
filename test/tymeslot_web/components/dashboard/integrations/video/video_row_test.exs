defmodule TymeslotWeb.Components.Dashboard.Integrations.Video.VideoRowTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.Dashboard.Integrations.Video.VideoRow

  defp integration(overrides) do
    base = %{
      id: 1,
      name: "Zoom",
      provider: "zoom",
      provider_account_email: "user@example.com",
      base_url: nil,
      custom_meeting_url: nil,
      is_active: true,
      needs_reauth: false
    }

    Map.merge(base, overrides)
  end

  defp render_video_row(integration_overrides, opts \\ []) do
    assigns = %{
      integration: integration(integration_overrides),
      testing_connection: Keyword.get(opts, :testing_connection),
      myself: "video-settings",
      icon_size: "compact",
      health_state: Keyword.get(opts, :health_state)
    }

    render_component(&VideoRow.video_row/1, assigns)
  end

  describe "needs_reauth badge" do
    test "renders Reconnect required badge when needs_reauth is true" do
      html = render_video_row(%{needs_reauth: true})

      assert html =~ "Reconnect required"
    end

    test "does not render Reconnect required badge when needs_reauth is false" do
      html = render_video_row(%{needs_reauth: false})

      refute html =~ "Reconnect required"
    end
  end

  describe "Reconnect button" do
    test "renders Reconnect button for zoom" do
      html = render_video_row(%{provider: "zoom"})

      assert html =~ ~s(phx-click="reconnect_integration")
      assert html =~ "Reconnect"
    end

    test "renders Reconnect button for google_meet" do
      html = render_video_row(%{provider: "google_meet"})

      assert html =~ ~s(phx-click="reconnect_integration")
    end

    test "renders Reconnect button for teams" do
      html = render_video_row(%{provider: "teams"})

      assert html =~ ~s(phx-click="reconnect_integration")
    end

    test "does not render Reconnect button for non-OAuth providers" do
      html = render_video_row(%{provider: "mirotalk"})

      refute html =~ ~s(phx-click="reconnect_integration")
    end
  end
end
