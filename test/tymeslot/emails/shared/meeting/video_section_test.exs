defmodule Tymeslot.Emails.Shared.Meeting.VideoSectionTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.Meeting.VideoSection
  alias Tymeslot.Emails.Shared.Styles
  alias Tymeslot.Utils.Colour

  describe "video_meeting_section/3" do
    test "sanitizes meeting URL" do
      malicious_url = "https://meet.example.com/<script>alert('xss')</script>"
      html = VideoSection.video_meeting_section(:confirmed, malicious_url)

      # URL should be sanitized in href attribute
      refute html =~ "<script>"
    end

    test "includes meeting URL in button" do
      url = "https://meet.example.com/room123"
      html = VideoSection.video_meeting_section(:confirmed, url)

      assert html =~ url
      assert html =~ "Join Meeting"
    end

    test "supports different intents" do
      url = "https://meet.example.com/room123"

      rendered =
        for intent <- [:confirmed, :alert, :cancelled] do
          html = VideoSection.video_meeting_section(intent, url)

          assert html =~ url
          assert html =~ "Join Meeting"

          html
        end

      # Each intent must paint its own colour band, so no two renders are alike.
      assert rendered |> Enum.uniq() |> length() == 3
    end

    test "allows custom title and button text" do
      url = "https://meet.example.com/room123"

      html =
        VideoSection.video_meeting_section(:confirmed, url,
          title: "Custom Title",
          button_text: "Custom Button"
        )

      assert html =~ "Custom Title"
      assert html =~ "Custom Button"
    end

    test "renders the join button on the deep accent variant, not the raw accent, for every intent" do
      url = "https://meet.example.com/room123"

      for intent <- [:confirmed, :alert, :cancelled] do
        html = VideoSection.video_meeting_section(intent, url)
        accent_deep = Styles.intent_accent_deep(intent)
        expected_text = Styles.button_text_color(accent_deep)

        assert html =~ ~s(background-color="#{accent_deep}")
        assert html =~ ~s(color="#{expected_text}")
      end
    end

    test "the stock join button clears 4.5:1 and resolves to light text, not dark ink" do
      url = "https://meet.example.com/room123"
      html = VideoSection.video_meeting_section(:confirmed, url)
      accent_deep = Styles.intent_accent_deep(:confirmed)
      expected_text = Styles.button_text_color(accent_deep)

      assert html =~ ~s(background-color="#{accent_deep}")
      assert html =~ ~s(color="#{Styles.surface()}")
      assert expected_text == Styles.surface()
      assert Colour.contrast_ratio(expected_text, accent_deep) >= 4.5
    end
  end

  describe "time_alert_badge/3" do
    test "sanitizes time text" do
      html = VideoSection.time_alert_badge(:alert, "<script>alert('xss')</script>30 minutes")

      refute html =~ "<script>"
      assert html =~ "30 minutes"
    end

    test "supports custom icon" do
      html = VideoSection.time_alert_badge(:confirmed, "Starting soon", icon: "⏰")

      assert html =~ "⏰"
      assert html =~ "Starting soon"
    end

    test "supports different intents" do
      rendered =
        for intent <- [:confirmed, :alert, :cancelled] do
          html = VideoSection.time_alert_badge(intent, "Time text")

          assert html =~ "Time text"

          html
        end

      # Each intent must paint its own colour band, so no two renders are alike.
      assert rendered |> Enum.uniq() |> length() == 3
    end
  end
end
