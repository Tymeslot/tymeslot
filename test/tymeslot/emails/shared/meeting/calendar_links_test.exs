defmodule Tymeslot.Emails.Shared.Meeting.CalendarLinksTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.Meeting.CalendarLinks

  defp meeting_fixture(overrides \\ %{}) do
    Map.merge(
      %{
        title: "Discovery Call",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        description: "Initial discussion",
        location: "Virtual"
      },
      overrides
    )
  end

  describe "calendar_links_section/1" do
    test "renders the heading" do
      html = CalendarLinks.calendar_links_section(meeting_fixture())

      assert html =~ "Add to your calendar"
    end

    test "renders three provider buttons" do
      html = CalendarLinks.calendar_links_section(meeting_fixture())

      assert html =~ "Google"
      assert html =~ "Outlook"
      assert html =~ "Yahoo"
    end

    test "embeds the generated provider URLs" do
      html = CalendarLinks.calendar_links_section(meeting_fixture())

      assert html =~ "calendar.google.com"
      assert html =~ "outlook"
      assert html =~ "yahoo"
    end

    test "URL-encodes the title in provider links (no raw XSS payload reaches href)" do
      html =
        CalendarLinks.calendar_links_section(
          meeting_fixture(%{title: "<script>alert('xss')</script>Meeting"})
        )

      refute html =~ "<script>alert"
    end
  end
end
