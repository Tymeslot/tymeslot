defmodule TymeslotWeb.Components.UIExtendedTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  import Phoenix.LiveViewTest
  import Phoenix.Component

  alias TymeslotWeb.Components.CoreComponents.Navigation
  alias TymeslotWeb.Components.Shared.TimeOptions
  alias TymeslotWeb.Shared.Auth.IconComponents
  alias TymeslotWeb.Themes.Shared.Assets

  describe "TimeOptions" do
    test "time_options/0 returns 24h interval pairs" do
      options = TimeOptions.time_options()
      assert length(options) == 24 * 4
      assert {"00:00", "00:00"} = hd(options)
      assert {"23:45", "23:45"} = List.last(options)
    end
  end

  describe "Themes.Shared.Assets" do
    test "get_video_config/1 returns config for themes" do
      rhythm = Assets.get_video_config(:rhythm)
      assert rhythm.crossfade_enabled == true
      refute Enum.empty?(rhythm.background_videos)

      quill = Assets.get_video_config(:quill)
      assert quill.background_videos == []
      assert quill.poster == nil

      default = Assets.get_video_config(:unknown)
      assert default.background_videos == []
    end

    test "helper functions return correct values" do
      assert is_list(Assets.video_sources(:rhythm))
      assert is_binary(Assets.video_poster(:rhythm))
      assert is_binary(Assets.fallback_gradient(:rhythm))
      assert Assets.crossfade_enabled?(:rhythm) == true
      assert Assets.crossfade_enabled?(:quill) == false
      assert is_list(Assets.video_ids(:rhythm))
    end
  end

  describe "CoreComponents.Navigation" do
    test "detail_row/1 renders correctly" do
      assigns = %{label: "Test Label", value: "Test Value"}
      html = render_component(&Navigation.detail_row/1, assigns)
      assert html =~ "Test Label"
      assert html =~ "Test Value"
    end

    test "back_link/1 renders correctly" do
      assigns = %{to: "/test"}

      html =
        render_component(
          fn assigns ->
            ~H"""
            <Navigation.back_link to={@to}>Back</Navigation.back_link>
            """
          end,
          assigns
        )

      assert html =~ "/test"
      assert html =~ "Back"
    end
  end

  describe "Auth.IconComponents" do
    test "icons render without error" do
      assert render_component(&IconComponents.email_icon/1, %{}) =~ "<svg"
      assert render_component(&IconComponents.success_icon/1, %{}) =~ "<svg"
      assert render_component(&IconComponents.email_verification_icon/1, %{}) =~ "<svg"
    end
  end
end
