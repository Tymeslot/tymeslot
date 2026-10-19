defmodule Tymeslot.Emails.Shared.TextBodyHelperTest do
  use ExUnit.Case, async: true

  @moduletag :emails

  alias Tymeslot.Emails.Shared.{MeetingComponents, TextBodyHelper}

  defp details(overrides) do
    Map.merge(
      %{
        date: ~D[2026-01-15],
        start_time: ~U[2026-01-15 14:00:00Z],
        duration: 60,
        location: "In person",
        location_type: :in_person_to_arrange,
        meeting_type: "Consultation"
      },
      overrides
    )
  end

  describe "format_meeting_details/2" do
    test "puts the arranged-after-booking note on the line after the location" do
      text = TextBodyHelper.format_meeting_details(details(%{}), "en")

      assert text =~
               "Location: In person\nThe address will be arranged with you after booking."
    end

    test "adds no note for a meeting with an address" do
      text =
        TextBodyHelper.format_meeting_details(
          details(%{location: "Berlin office (Friedrichstrasse 1)", location_type: :in_person}),
          "en"
        )

      assert text =~ "Location: Berlin office (Friedrichstrasse 1)"
      refute text =~ "arranged with you after booking"
    end

    test "writes the note in the recipient's language" do
      text = TextBodyHelper.format_meeting_details(details(%{}), "de")

      assert text =~ "Die Adresse wird nach der Buchung mit Ihnen abgestimmt."
    end
  end

  describe "format_meeting_details/2 next-day end" do
    test "names the end when the meeting runs past midnight" do
      start = ~U[2026-01-15 23:00:00Z]

      text =
        TextBodyHelper.format_meeting_details(details(%{start_time: start, duration: 120}), "en")

      assert text =~ "Time: 11:00 PM UTC, ends 01:00 AM on Fri 16 Jan\nDuration: 2 hours"
    end

    test "says nothing for a meeting ending the same day" do
      text =
        TextBodyHelper.format_meeting_details(
          details(%{start_time: ~U[2026-01-15 23:00:00Z], duration: 30}),
          "en"
        )

      refute text =~ "ends"
    end
  end

  describe "format_meeting_details/2 time line" do
    test "states the time in the zone the map names, as the HTML card does" do
      details =
        details(%{
          start_time: DateTime.shift_zone!(~U[2026-01-15 09:00:00Z], "Asia/Kolkata"),
          timezone: "Asia/Kolkata"
        })

      text = TextBodyHelper.format_meeting_details(details, "en")
      card = MeetingComponents.meeting_details_table(details, "en")

      assert text =~ "Time: 02:30 PM IST (Asia/Kolkata)\nDuration: 1 hour"
      assert card =~ "02:30 PM IST (Asia/Kolkata)"
    end

    test "names the zone the start time is in, not the one the map claims" do
      text =
        TextBodyHelper.format_meeting_details(
          details(%{start_time: ~U[2026-01-15 14:00:00Z], timezone: "Bad/Zone"}),
          "en"
        )

      assert text =~ "Time: 02:00 PM UTC\n"
      refute text =~ "Bad/Zone"
    end

    test "names no zone for a start time in Etc/UTC, as an ad-hoc meeting has" do
      text =
        TextBodyHelper.format_meeting_details(
          details(%{start_time: ~U[2026-01-15 14:00:00Z], timezone: "Etc/UTC"}),
          "en"
        )

      assert text =~ "Time: 02:00 PM UTC\n"
      refute text =~ "Etc/UTC"
    end

    test "names no zone for UTC" do
      text = TextBodyHelper.format_meeting_details(details(%{timezone: "UTC"}), "en")

      assert text =~ "Time: 02:00 PM UTC\n"
    end

    test "uses the organiser's clock when the map carries one" do
      text = TextBodyHelper.format_meeting_details(details(%{time_format: "24h"}), "en")

      assert text =~ "Time: 14:00 UTC"
    end

    test "states an all-day event's days, with no clock time" do
      text =
        TextBodyHelper.format_meeting_details(
          details(%{all_day: true, last_date: ~D[2026-01-17], start_time: nil, duration: nil}),
          "en"
        )

      assert text =~ "Time: All day, until"
      assert text =~ "Duration: 3 days"
    end
  end

  describe "format_action_links/2" do
    test "lists every action the payload carries a URL for, in order" do
      text =
        TextBodyHelper.format_action_links(
          %{
            reschedule_url: "https://example.com/r",
            cancel_url: "https://example.com/c",
            dashboard_url: "https://example.com/d"
          },
          "en"
        )

      assert text =~
               "ACTIONS:\nReschedule: https://example.com/r\nCancel: https://example.com/c\nOpen in dashboard: https://example.com/d"
    end

    test "leaves out an action with no URL" do
      text = TextBodyHelper.format_action_links(%{reschedule_url: "https://example.com/r"}, "en")

      assert text =~ "Reschedule: https://example.com/r"
      refute text =~ "Cancel:"
    end

    test "is empty when there is no action" do
      assert TextBodyHelper.format_action_links(%{}, "en") == ""
    end
  end

  describe "format_video_section/2" do
    test "lists a web join link" do
      text = TextBodyHelper.format_video_section("https://meet.example.com/room", "en")

      assert text =~ "JOIN VIDEO MEETING:\nhttps://meet.example.com/room"
    end

    test "is empty for a bare room id, a mailto address or an unsafe link" do
      for url <- ["room-1234", "mailto:host@example.com", "javascript:alert(1)", "", nil] do
        assert TextBodyHelper.format_video_section(url, "en") == "", inspect(url)
      end
    end
  end

  describe "format_custom_answers/2" do
    @details %{
      custom_fields_snapshot: [
        %{"id" => "start", "type" => "date", "label" => "Start"},
        %{"id" => "terms", "type" => "note", "label" => "Terms"}
      ],
      custom_field_answers: %{
        "start" => "2027-01-19",
        "terms" => %{"confirmed" => true, "confirmed_at" => "2027-01-02T09:00:00Z"}
      }
    }

    test "writes a date answer out in the recipient's locale" do
      assert TextBodyHelper.format_custom_answers(@details, "de") =~ "Start: 19. Januar 2027"
      assert TextBodyHelper.format_custom_answers(@details, "en") =~ "Start: 19 January 2027"
    end

    test "shows a ticked note without its timestamp" do
      text = TextBodyHelper.format_custom_answers(@details, "de")

      assert text =~ "Terms: ✓ Bestätigt\n"
      refute text =~ "2027-01-02"
    end
  end
end
