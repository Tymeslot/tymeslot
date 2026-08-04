defmodule Tymeslot.Integrations.Calendar.CalendarEventBuilderTest do
  use ExUnit.Case, async: true

  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.CalendarEventBuilder

  @base_meeting %{
    uid: "abc-123",
    title: "Team Sync",
    description: "Quarterly review",
    start_time: ~U[2026-05-01 10:00:00Z],
    end_time: ~U[2026-05-01 11:00:00Z],
    attendee_timezone: "Europe/London",
    meeting_url: nil,
    location: nil,
    organizer_name: "Bob",
    organizer_email: "bob@example.com",
    attendee_name: "Alice",
    attendee_email: "alice@example.com",
    attendee_message: nil
  }

  describe "build_event_data/1" do
    test "maps all standard fields from the meeting" do
      meeting = @base_meeting

      result = CalendarEventBuilder.build_event_data(meeting)

      assert result.uid == "abc-123"
      assert result.summary == "Team Sync"
      assert result.start_time == ~U[2026-05-01 10:00:00Z]
      assert result.end_time == ~U[2026-05-01 11:00:00Z]
      assert result.timezone == "Europe/London"
      assert result.organizer_name == "Bob"
      assert result.organizer_email == "bob@example.com"
      assert result.attendee_name == "Alice"
      assert result.attendee_email == "alice@example.com"
    end

    test "prefers meeting_url over location for the location field" do
      meeting = %{
        @base_meeting
        | meeting_url: "https://meet.example.com/room",
          location: "Office"
      }

      result = CalendarEventBuilder.build_event_data(meeting)

      assert result.location == "https://meet.example.com/room"
    end

    test "falls back to location when meeting_url is nil" do
      meeting = %{@base_meeting | meeting_url: nil, location: "Conference Room B"}

      result = CalendarEventBuilder.build_event_data(meeting)

      assert result.location == "Conference Room B"
    end

    test "leaves location nil when both meeting_url and location are nil" do
      meeting = %{@base_meeting | meeting_url: nil, location: nil}

      result = CalendarEventBuilder.build_event_data(meeting)

      assert result.location == nil
    end

    test "description is assembled from build_event_description" do
      meeting = %{@base_meeting | attendee_message: "Looking forward to it!"}

      result = CalendarEventBuilder.build_event_data(meeting)

      assert result.description =~ "Quarterly review"
      assert result.description =~ "Looking forward to it!"
    end

    test "carries the meeting_url through as conference_url" do
      meeting = %{@base_meeting | meeting_url: "https://meet.example.com/room"}

      result = CalendarEventBuilder.build_event_data(meeting)

      assert result.conference_url == "https://meet.example.com/room"
    end

    test "defaults transparency to opaque (busy)" do
      result = CalendarEventBuilder.build_event_data(@base_meeting)

      assert result.transparency == :opaque
    end

    test "maps show_as_free to transparent transparency" do
      meeting = Map.put(@base_meeting, :show_as_free, true)

      result = CalendarEventBuilder.build_event_data(meeting)

      assert result.transparency == :transparent
    end
  end

  describe "build_attachments/1" do
    test "returns empty list when attachments_snapshot is nil" do
      assert CalendarEventBuilder.build_attachments(@base_meeting) == []
    end

    test "returns empty list when attachments_snapshot is an empty list" do
      meeting = Map.put(@base_meeting, :attachments_snapshot, [])

      assert CalendarEventBuilder.build_attachments(meeting) == []
    end

    test "builds attachment map from string-keyed snapshot entry" do
      meeting =
        Map.put(@base_meeting, :attachments_snapshot, [
          %{
            "filename" => "report.pdf",
            "stored_path" => "meetings/123/report.pdf",
            "content_type" => "application/pdf"
          }
        ])

      [attachment] = CalendarEventBuilder.build_attachments(meeting)

      assert attachment.filename == "report.pdf"
      assert attachment.content_type == "application/pdf"
      assert String.ends_with?(attachment.url, "/uploads/meetings/123/report.pdf")
    end

    test "falls back to atom keys when string keys are absent" do
      meeting =
        Map.put(@base_meeting, :attachments_snapshot, [
          %{
            filename: "deck.pptx",
            stored_path: "meetings/456/deck.pptx",
            content_type:
              "application/vnd.openxmlformats-officedocument.presentationml.presentation"
          }
        ])

      [attachment] = CalendarEventBuilder.build_attachments(meeting)

      assert attachment.filename == "deck.pptx"
      assert String.ends_with?(attachment.url, "/uploads/meetings/456/deck.pptx")
    end

    test "excludes entries whose stored_path is nil" do
      meeting =
        Map.put(@base_meeting, :attachments_snapshot, [
          %{
            "filename" => "orphan.pdf",
            "stored_path" => nil,
            "content_type" => "application/pdf"
          },
          %{
            "filename" => "valid.pdf",
            "stored_path" => "meetings/789/valid.pdf",
            "content_type" => "application/pdf"
          }
        ])

      [attachment] = CalendarEventBuilder.build_attachments(meeting)

      assert attachment.filename == "valid.pdf"
    end

    test "builds an absolute download URL by prepending the endpoint host" do
      meeting =
        Map.put(@base_meeting, :attachments_snapshot, [
          %{
            "filename" => "slides.pdf",
            "stored_path" => "meetings/abc/slides.pdf",
            "content_type" => "application/pdf"
          }
        ])

      [attachment] = CalendarEventBuilder.build_attachments(meeting)

      assert String.starts_with?(attachment.url, "http")
      assert String.contains?(attachment.url, "/uploads/meetings/abc/slides.pdf")
    end
  end

  describe "build_event_data/1 — attachments" do
    test "attachments key holds the built attachment list" do
      meeting =
        Map.put(@base_meeting, :attachments_snapshot, [
          %{
            "filename" => "slides.pdf",
            "stored_path" => "meetings/abc/slides.pdf",
            "content_type" => "application/pdf"
          }
        ])

      result = CalendarEventBuilder.build_event_data(meeting)

      [attachment] = result.attachments
      assert attachment.filename == "slides.pdf"
      assert attachment.content_type == "application/pdf"
      assert String.ends_with?(attachment.url, "/uploads/meetings/abc/slides.pdf")
    end

    test "description carries an Attachments links block when snapshot is present" do
      meeting =
        Map.put(@base_meeting, :attachments_snapshot, [
          %{
            "filename" => "slides.pdf",
            "stored_path" => "meetings/abc/slides.pdf",
            "content_type" => "application/pdf"
          }
        ])

      result = CalendarEventBuilder.build_event_data(meeting)

      assert result.description =~ "Attachments:\nslides.pdf:"
      assert result.description =~ "/uploads/meetings/abc/slides.pdf"
    end

    test "attachments list is empty and description has no Attachments block when snapshot is nil" do
      result = CalendarEventBuilder.build_event_data(@base_meeting)

      assert result.attachments == []
      refute result.description =~ "Attachments:"
    end
  end

  describe "build_event_data/1 — reminders" do
    test "carries the meeting's reminders through as provider alarms" do
      meeting = Map.put(@base_meeting, :reminders, [%{value: 30, unit: "minutes"}])

      result = CalendarEventBuilder.build_event_data(meeting)

      assert result.reminders == [%{method: :popup, minutes_before: 30}]
    end

    test "expresses hour and day lead times in minutes" do
      meeting =
        Map.put(@base_meeting, :reminders, [
          %{value: 2, unit: "hours"},
          %{value: 1, unit: "days"}
        ])

      result = CalendarEventBuilder.build_event_data(meeting)

      assert result.reminders == [
               %{method: :popup, minutes_before: 120},
               %{method: :popup, minutes_before: 1440}
             ]
    end

    test "reads reminders that round-tripped through the JSONB column as string keys" do
      meeting = Map.put(@base_meeting, :reminders, [%{"value" => 15, "unit" => "minutes"}])

      result = CalendarEventBuilder.build_event_data(meeting)

      assert result.reminders == [%{method: :popup, minutes_before: 15}]
    end

    test "drops an unreadable reminder rather than emitting a malformed alarm" do
      meeting =
        Map.put(@base_meeting, :reminders, [
          %{value: 10, unit: "fortnights"},
          %{value: 10, unit: "minutes"}
        ])

      result = CalendarEventBuilder.build_event_data(meeting)

      assert result.reminders == [%{method: :popup, minutes_before: 10}]
    end

    test "emits no alarms when the meeting carries no reminders" do
      assert CalendarEventBuilder.build_event_data(@base_meeting).reminders == []

      assert CalendarEventBuilder.build_event_data(Map.put(@base_meeting, :reminders, nil)).reminders ==
               []
    end
  end

  describe "build_event_description/1" do
    test "prepends attendee identity and returns only the base description otherwise" do
      meeting = %{@base_meeting | attendee_message: nil, meeting_url: nil}

      assert CalendarEventBuilder.build_event_description(meeting) ==
               "Attendee: Alice <alice@example.com>\n\nQuarterly review"
    end

    test "appends attendee message with section header when present" do
      meeting = %{@base_meeting | attendee_message: "Please bring slides.", meeting_url: nil}

      result = CalendarEventBuilder.build_event_description(meeting)

      assert result ==
               "Attendee: Alice <alice@example.com>\n\nQuarterly review\n\nMessage from attendee:\nPlease bring slides."
    end

    test "appends video meeting URL with section header when present" do
      meeting = %{
        @base_meeting
        | attendee_message: nil,
          meeting_url: "https://meet.example.com/room"
      }

      result = CalendarEventBuilder.build_event_description(meeting)

      assert result ==
               "Attendee: Alice <alice@example.com>\n\nQuarterly review\n\nVideo meeting: https://meet.example.com/room"
    end

    test "appends both attendee message and video URL when both are present" do
      meeting = %{
        @base_meeting
        | attendee_message: "See you there!",
          meeting_url: "https://meet.example.com/room"
      }

      result = CalendarEventBuilder.build_event_description(meeting)

      assert result ==
               "Attendee: Alice <alice@example.com>\n\nQuarterly review\n\nMessage from attendee:\nSee you there!\n\nVideo meeting: https://meet.example.com/room"
    end

    test "handles nil base description without crashing" do
      meeting = %{@base_meeting | description: nil, attendee_message: nil, meeting_url: nil}

      result = CalendarEventBuilder.build_event_description(meeting)

      assert result == "Attendee: Alice <alice@example.com>\n\n"
    end

    test "handles nil base description with attendee message" do
      meeting = %{@base_meeting | description: nil, attendee_message: "Hi!", meeting_url: nil}

      result = CalendarEventBuilder.build_event_description(meeting)

      assert result == "Attendee: Alice <alice@example.com>\n\n\n\nMessage from attendee:\nHi!"
    end

    # Issue #41: this line is the only place the organiser sees the
    # attendee's identity inside their calendar app once the ATTENDEE block
    # is removed from the CalDAV write payload. If the prefix changes the
    # user-facing UX breaks silently — assert the exact shape.
    test "falls back to email-only identity when attendee_name is missing" do
      meeting = %{
        @base_meeting
        | attendee_name: nil,
          attendee_message: nil,
          meeting_url: nil
      }

      result = CalendarEventBuilder.build_event_description(meeting)

      assert result == "Attendee: alice@example.com\n\nQuarterly review"
    end

    test "omits the identity line entirely when attendee_email is missing" do
      meeting = %{
        @base_meeting
        | attendee_email: nil,
          attendee_name: nil,
          attendee_message: nil,
          meeting_url: nil
      }

      result = CalendarEventBuilder.build_event_description(meeting)

      assert result == "Quarterly review"
    end

    test "appends custom question answers after the attendee message" do
      meeting =
        Map.merge(@base_meeting, %{
          attendee_message: "Please bring slides.",
          meeting_url: nil,
          custom_fields_snapshot: [
            %{"id" => "f1", "type" => "short_text", "label" => "Company"},
            %{"id" => "f2", "type" => "yes_no", "label" => "First time?"}
          ],
          custom_field_answers: %{"f1" => "Acme Ltd", "f2" => true}
        })

      result = CalendarEventBuilder.build_event_description(meeting)

      assert result ==
               "Attendee: Alice <alice@example.com>\n\nQuarterly review\n\nMessage from attendee:\nPlease bring slides.\n\nAdditional details:\nCompany: Acme Ltd\nFirst time?: Yes"
    end

    test "places custom answers before the video meeting link" do
      meeting =
        Map.merge(@base_meeting, %{
          attendee_message: nil,
          meeting_url: "https://meet.example.com/room",
          custom_fields_snapshot: [
            %{"id" => "f1", "type" => "short_text", "label" => "Company"}
          ],
          custom_field_answers: %{"f1" => "Acme Ltd"}
        })

      result = CalendarEventBuilder.build_event_description(meeting)

      assert result ==
               "Attendee: Alice <alice@example.com>\n\nQuarterly review\n\nAdditional details:\nCompany: Acme Ltd\n\nVideo meeting: https://meet.example.com/room"
    end

    test "omits the custom answers section when no answer renders a value" do
      meeting =
        Map.merge(@base_meeting, %{
          attendee_message: nil,
          meeting_url: nil,
          custom_fields_snapshot: [
            %{"id" => "f1", "type" => "short_text", "label" => "Company"}
          ],
          custom_field_answers: %{}
        })

      result = CalendarEventBuilder.build_event_description(meeting)

      assert result == "Attendee: Alice <alice@example.com>\n\nQuarterly review"
    end
  end
end
