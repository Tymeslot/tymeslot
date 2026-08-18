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
      sources = Assets.video_sources(:rhythm)
      assert length(sources) == 4
      assert Enum.all?(sources, &String.starts_with?(&1.src, "/videos/backgrounds/rhythm-"))

      assert Assets.video_poster(:rhythm) == "/images/ui/posters/rhythm-background-poster.webp"
      assert Assets.fallback_gradient(:rhythm) =~ "linear-gradient("
      assert Assets.crossfade_enabled?(:rhythm) == true
      assert Assets.crossfade_enabled?(:quill) == false

      assert Assets.video_ids(:rhythm) == [
               "rhythm-background-video-1",
               "rhythm-background-video-2"
             ]
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
    # "renders an <svg>" is true of every heroicon, so each function's own
    # glyph path and colour are pinned: swapping two of these components, or
    # letting a renamed icon fall through to the unknown-icon branch, has to
    # fail here.
    test "email_icon renders the solid mini envelope in the input adornment colour" do
      html = render_component(&IconComponents.email_icon/1, %{})

      assert html =~ ~s(viewBox="0 0 20 20")
      assert html =~ ~s(fill="currentColor")

      assert html =~
               "M3 4a2 2 0 0 0-2 2v1.161l8.441 4.221a1.25 1.25 0 0 0 1.118 0L19 7.162V6a2 2 0 0 0-2-2H3Z"

      assert html =~ "text-tymeslot-400"
    end

    test "success_icon renders the outline check-circle in green" do
      html = render_component(&IconComponents.success_icon/1, %{})

      assert html =~ ~s(viewBox="0 0 24 24")
      assert html =~ "M9 12.75 11.25 15 15 9.75M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z"
      assert html =~ "text-green-500"
    end

    test "email_verification_icon renders the outline envelope in the hero colour" do
      html = render_component(&IconComponents.email_verification_icon/1, %{})

      assert html =~ ~s(viewBox="0 0 24 24")

      assert html =~
               "M21.75 6.75v10.5a2.25 2.25 0 0 1-2.25 2.25h-15a2.25 2.25 0 0 1-2.25-2.25V6.75"

      assert html =~ "text-turquoise-50"
    end
  end
end
