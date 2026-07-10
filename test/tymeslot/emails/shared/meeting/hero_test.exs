defmodule Tymeslot.Emails.Shared.Meeting.HeroTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.Meeting.Hero

  describe "meeting_details_table/1" do
    test "sanitizes user-provided location" do
      details = %{
        date: ~D[2026-01-15],
        start_time: ~U[2026-01-15 14:00:00Z],
        duration: 60,
        location: "<script>alert('xss')</script>Conference Room"
      }

      html = Hero.meeting_details_table(details, "en")

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
      assert html =~ "Conference Room"
    end

    test "sanitizes meeting type" do
      details = %{
        date: ~D[2026-01-15],
        start_time: ~U[2026-01-15 14:00:00Z],
        duration: 60,
        meeting_type: "<img src=x onerror=alert(1)>Demo"
      }

      html = Hero.meeting_details_table(details, "en")

      refute html =~ "<img src=x"
      assert html =~ "Demo"
    end

    test "handles nil location gracefully" do
      details = %{
        date: ~D[2026-01-15],
        start_time: ~U[2026-01-15 14:00:00Z],
        duration: 60,
        location: nil
      }

      html = Hero.meeting_details_table(details, "en")

      assert html =~ "TBD"
    end

    test "includes all meeting details" do
      details = %{
        date: ~D[2026-01-15],
        start_time: ~U[2026-01-15 14:00:00Z],
        duration: 60,
        location: "Virtual Meeting",
        meeting_type: "Discovery Call"
      }

      html = Hero.meeting_details_table(details, "en")

      assert html =~ "1 hour"
      assert html =~ "Virtual Meeting"
      assert html =~ "Discovery Call"
    end
  end
end
