defmodule Tymeslot.Integrations.Calendar.IcsGeneratorTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.IcsGenerator

  describe "generate_ics/1" do
    test "generates valid ICS content with required fields" do
      meeting_details = %{
        title: "Test Meeting",
        description: "This is a test meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "test-meeting-123",
        organizer_email: "organizer@example.com",
        organizer_name: "John Doe"
      }

      # Ensure we use the domain from configuration
      domain = Application.get_env(:tymeslot, :email)[:domain]
      ics_content = IcsGenerator.generate_ics(meeting_details)

      assert ics_content =~ "BEGIN:VCALENDAR"
      assert ics_content =~ "END:VCALENDAR"
      assert ics_content =~ "BEGIN:VEVENT"
      assert ics_content =~ "END:VEVENT"
      assert ics_content =~ "SUMMARY;LANGUAGE=en:Test Meeting"
      assert ics_content =~ "UID:test-meeting-123@#{domain}"
    end

    test "includes organizer information" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "meeting-123",
        organizer_email: "john@example.com",
        organizer_name: "John Smith"
      }

      ics_content = IcsGenerator.generate_ics(meeting_details)

      assert ics_content =~ "ORGANIZER"
      assert ics_content =~ "john@example.com"
      assert ics_content =~ "John Smith"
    end

    test "includes attendee information when provided" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "meeting-123",
        organizer_email: "john@example.com",
        attendee_email: "jane@example.com",
        attendee_name: "Jane Doe"
      }

      ics_content = IcsGenerator.generate_ics(meeting_details)

      assert ics_content =~ "ATTENDEE"
      assert ics_content =~ "jane@example.com"
      assert ics_content =~ "Jane Doe"
    end

    test "handles missing optional attendee information" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "meeting-123",
        organizer_email: "john@example.com"
      }

      ics_content = IcsGenerator.generate_ics(meeting_details)

      # Should still generate valid ICS without attendee
      assert ics_content =~ "BEGIN:VCALENDAR"
    end

    test "includes location when provided" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "meeting-123",
        organizer_email: "john@example.com",
        location: "Conference Room A"
      }

      ics_content = IcsGenerator.generate_ics(meeting_details)

      assert ics_content =~ "LOCATION"
      assert ics_content =~ "Conference Room A"
    end

    test "uses 'Video Call' as location when meeting_url is provided" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "meeting-123",
        organizer_email: "john@example.com",
        meeting_url: "https://meet.example.com/room123"
      }

      ics_content = IcsGenerator.generate_ics(meeting_details)

      assert ics_content =~ "LOCATION;LANGUAGE=en:Video Call"
    end

    test "emits a CONFERENCE property when meeting_url is provided" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "meeting-123",
        organizer_email: "john@example.com",
        meeting_url: "https://meet.example.com/room123"
      }

      # Unfold RFC 5545 line folds before asserting the URL survives intact.
      ics_content =
        meeting_details |> IcsGenerator.generate_ics() |> String.replace("\r\n ", "")

      assert ics_content =~
               ~s(CONFERENCE;VALUE=URI;FEATURE=VIDEO;LABEL="Join the video call":https://meet.example.com/room123)
    end

    test "includes video URL in description when provided" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "meeting-123",
        organizer_email: "john@example.com",
        meeting_url: "https://meet.example.com/room123"
      }

      ics_content = IcsGenerator.generate_ics(meeting_details)

      assert ics_content =~ "Video meeting: https://meet.example.com/room123"
    end

    test "includes attendee message in description when provided" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "meeting-123",
        organizer_email: "john@example.com",
        attendee_name: "Jane",
        attendee_message: "Looking forward to discussing the project"
      }

      # Unfold RFC 5545 line folds — the LANGUAGE param lengthens the
      # DESCRIPTION line, so the message text may now wrap mid-word.
      ics_content =
        meeting_details |> IcsGenerator.generate_ics() |> String.replace("\r\n ", "")

      assert ics_content =~ "Message from Jane"
      assert ics_content =~ "Looking forward to discussing the project"
    end
  end

  describe "locale-aware ICS content" do
    test "translates 'Video Call' location into German" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "meeting-123",
        organizer_email: "john@example.com",
        meeting_url: "https://meet.example.com/room123"
      }

      ics_content = IcsGenerator.generate_ics(meeting_details, "de")

      assert ics_content =~ "LOCATION;LANGUAGE=de:Videoanruf"
      refute ics_content =~ "Video Call"
    end

    test "translates video meeting label in description into German" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "meeting-123",
        organizer_email: "john@example.com",
        meeting_url: "https://meet.example.com/room123"
      }

      ics_content = IcsGenerator.generate_ics(meeting_details, "de")

      assert ics_content =~ "Video-Meeting:"
      refute ics_content =~ "Video meeting:"
    end

    test "translates attendee message label into German" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "meeting-123",
        organizer_email: "john@example.com",
        attendee_name: "Klaus",
        attendee_message: "Freue mich auf unser Gespräch"
      }

      ics_content = IcsGenerator.generate_ics(meeting_details, "de")

      assert ics_content =~ "Nachricht von Klaus:"
      refute ics_content =~ "Message from Klaus:"
    end

    test "English locale produces English strings" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "meeting-123",
        organizer_email: "john@example.com",
        meeting_url: "https://meet.example.com/room123"
      }

      ics_content = IcsGenerator.generate_ics(meeting_details, "en")

      assert ics_content =~ "LOCATION;LANGUAGE=en:Video Call"
    end
  end

  describe "generate_ics_attachment/3" do
    test "creates valid Swoosh attachment with ICS content" do
      meeting_details = %{
        title: "Test Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "meeting-123",
        organizer_email: "john@example.com"
      }

      attachment = IcsGenerator.generate_ics_attachment(meeting_details)

      assert %Swoosh.Attachment{} = attachment
      assert attachment.filename == "meeting.ics"
      assert attachment.content_type =~ "text/calendar"
      assert attachment.content_type =~ "method=PUBLISH"
      assert attachment.data =~ "BEGIN:VCALENDAR"
    end

    test "uses custom filename when provided" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "meeting-123",
        organizer_email: "john@example.com"
      }

      attachment =
        IcsGenerator.generate_ics_attachment(meeting_details, "en", "custom-invite.ics")

      assert attachment.filename == "custom-invite.ics"
    end

    test "advertises METHOD:PUBLISH (not REQUEST) to suppress recipient-side iMIP auto-import" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "meeting-123",
        organizer_email: "john@example.com"
      }

      attachment = IcsGenerator.generate_ics_attachment(meeting_details)

      assert attachment.content_type == "text/calendar; charset=utf-8; method=PUBLISH"
      assert attachment.data =~ "METHOD:PUBLISH"
      refute attachment.data =~ "METHOD:REQUEST"
    end
  end

  describe "generate_ics_cancel_attachment/4" do
    test "emits METHOD:PUBLISH + STATUS:CANCELLED with the given SEQUENCE" do
      meeting_details = %{
        title: "Cancelled Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "cancel-me-123",
        organizer_email: "organizer@example.com",
        attendee_email: "jane@example.com"
      }

      attachment = IcsGenerator.generate_ics_cancel_attachment(meeting_details, 3)

      assert %Swoosh.Attachment{} = attachment
      assert attachment.content_type == "text/calendar; charset=utf-8; method=PUBLISH"
      assert attachment.data =~ "METHOD:PUBLISH"
      refute attachment.data =~ "METHOD:CANCEL"
      assert attachment.data =~ "SEQUENCE:3"
      assert attachment.data =~ "STATUS:CANCELLED"
    end
  end

  describe "generate_ics_update_attachment/4" do
    test "advertises METHOD:PUBLISH (not REQUEST) in content-type and data" do
      meeting_details = %{
        title: "Updated Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "update-me-123",
        organizer_email: "organizer@example.com"
      }

      attachment = IcsGenerator.generate_ics_update_attachment(meeting_details, 1)

      assert attachment.content_type =~ "method=PUBLISH"
      assert attachment.data =~ "METHOD:PUBLISH"
      refute attachment.data =~ "METHOD:REQUEST"
    end

    test "includes SEQUENCE line reflecting the given sequence number" do
      meeting_details = %{
        title: "Updated Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "update-me-123",
        organizer_email: "organizer@example.com"
      }

      attachment = IcsGenerator.generate_ics_update_attachment(meeting_details, 2)

      assert attachment.data =~ "SEQUENCE:2"
    end

    test "retains STATUS:CONFIRMED on an update" do
      meeting_details = %{
        title: "Updated Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "update-me-123",
        organizer_email: "organizer@example.com"
      }

      attachment = IcsGenerator.generate_ics_update_attachment(meeting_details, 1)

      assert attachment.data =~ "STATUS:CONFIRMED"
      refute attachment.data =~ "STATUS:CANCELLED"
    end

    test "ORGANIZER and ATTENDEE lines carry SCHEDULE-AGENT=CLIENT" do
      meeting_details = %{
        title: "Updated Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "update-me-123",
        organizer_email: "organizer@example.com",
        organizer_name: "Alice",
        attendee_email: "bob@example.com",
        attendee_name: "Bob"
      }

      attachment = IcsGenerator.generate_ics_update_attachment(meeting_details, 1)

      assert attachment.data =~ ~r/^ORGANIZER;SCHEDULE-AGENT=CLIENT[;:]/m
      assert attachment.data =~ ~r/^ATTENDEE;SCHEDULE-AGENT=CLIENT[;:]/m
    end
  end

  describe "DST and timezone serialisation" do
    # `format_datetime_utc/1` in the generator always shifts to UTC and
    # appends the `Z` suffix. These tests pin that invariant on DST
    # boundary days where a buggy renderer that stripped the offset
    # without shifting would silently leak local time.
    #
    # Tymeslot never emits TZID-bound VTIMEZONE blocks; the wire format
    # is always Z-suffixed UTC, so any regression that dropped the
    # `shift_zone!("Etc/UTC")` step would surface as a mismatch between
    # the DateTime's UTC instant and the rendered string.

    test "spring-forward: Europe/London DateTime renders as its UTC instant" do
      # Last Sunday of March 2026, UK springs forward at 01:00 UTC.
      # 10:30 Europe/London on that day is BST (+01:00) — 09:30 UTC.
      # A buggy renderer that stripped the offset without shifting would
      # emit T103000Z here.
      {:ok, bst_dt} = DateTime.from_naive(~N[2026-03-29 10:30:00], "Europe/London")
      {:ok, bst_end} = DateTime.from_naive(~N[2026-03-29 11:30:00], "Europe/London")

      meeting_details = %{
        title: "DST spring forward",
        start_time: bst_dt,
        end_time: bst_end,
        uid: "dst-spring",
        organizer_email: "x@example.com"
      }

      ics = IcsGenerator.generate_ics(meeting_details)

      assert ics =~ "DTSTART:20260329T093000Z"
      assert ics =~ "DTEND:20260329T103000Z"
    end

    test "fall-back: Europe/Berlin DateTime after the boundary renders as its UTC instant" do
      # Last Sunday of October 2026, Europe/Berlin falls back at 01:00 UTC
      # (03:00 local → 02:00 local). 02:30 local is *ambiguous* — both
      # the CEST (+02:00) and CET (+01:00) arms of that wall clock are
      # valid. `DateTime.from_naive/2` returns both arms as
      # `{:ambiguous, cest_dt, cet_dt}`; callers must resolve. We pick
      # the post-boundary CET arm (01:30 UTC) — what a calendar client
      # sends after the user re-ticks their clock — and verify the
      # renderer honours that choice rather than silently picking the
      # other arm.
      {:ambiguous, _cest_dt, cet_dt} =
        DateTime.from_naive(~N[2026-10-25 02:30:00], "Europe/Berlin")

      {:ok, cet_end} = DateTime.from_naive(~N[2026-10-25 03:30:00], "Europe/Berlin")

      meeting_details = %{
        title: "DST fall back",
        start_time: cet_dt,
        end_time: cet_end,
        uid: "dst-fall",
        organizer_email: "x@example.com"
      }

      ics = IcsGenerator.generate_ics(meeting_details)

      assert ics =~ "DTSTART:20261025T013000Z"
      assert ics =~ "DTEND:20261025T023000Z"
    end
  end
end
