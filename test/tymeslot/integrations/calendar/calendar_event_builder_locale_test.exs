defmodule Tymeslot.Integrations.Calendar.CalendarEventBuilderLocaleTest do
  @moduledoc """
  The event written to the host's calendar is labelled in the host's language.

  The attendee's copy of the booking is a separate document — `ICSGenerator`
  builds it in the attendee's language — so nothing here speaks for them.
  """

  # The database holds the organiser whose language the entry is written in.
  use Tymeslot.DataCase, async: true

  @moduletag :calendar

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarEventBuilder

  @meeting %{
    uid: "abc-123",
    title: "Team Sync",
    description: "Quarterly review",
    start_time: ~U[2026-05-01 10:00:00Z],
    end_time: ~U[2026-05-01 11:00:00Z],
    attendee_timezone: "Europe/London",
    meeting_url: "https://meet.example.com/room",
    location: nil,
    organizer_name: "Bob",
    organizer_email: "bob@example.com",
    attendee_name: "Alice",
    attendee_email: "alice@example.com",
    attendee_message: "Please bring slides.",
    custom_fields_snapshot: [%{"id" => "q1", "label" => "Topic", "type" => "text"}],
    custom_field_answers: %{"q1" => "Budget"},
    attachments_snapshot: [
      %{"filename" => "report.pdf", "stored_path" => "meetings/123/report.pdf"}
    ]
  }

  describe "build_event_description/1" do
    test "labels the entry in the organiser's language" do
      organiser = insert(:user, locale: "de")

      description =
        @meeting
        |> Map.put(:organizer_user_id, organiser.id)
        |> CalendarEventBuilder.build_event_description()

      assert description =~ "Teilnehmer: Alice <alice@example.com>"
      assert description =~ "Nachricht vom Teilnehmer:"
      assert description =~ "Weitere Details:"
      assert description =~ "Anhänge:"
      assert description =~ "Video-Meeting: https://meet.example.com/room"

      # What the host typed, and what the attendee answered, are theirs — only
      # the labels around them are translated.
      assert description =~ "Quarterly review"
      assert description =~ "Please bring slides."
      assert description =~ "Topic: Budget"
    end

    test "falls back to the default language when the organiser has not chosen one" do
      organiser = insert(:user, locale: nil)

      description =
        @meeting
        |> Map.put(:organizer_user_id, organiser.id)
        |> CalendarEventBuilder.build_event_description()

      assert description =~ "Attendee: Alice <alice@example.com>"
      assert description =~ "Video meeting: https://meet.example.com/room"
    end

    test "falls back to the default language when the meeting names no organiser" do
      description = CalendarEventBuilder.build_event_description(@meeting)

      assert description =~ "Attendee: Alice <alice@example.com>"
    end
  end

  describe "the note's heading" do
    test "names the organiser on a meeting they created themselves" do
      organiser = insert(:user, locale: "de")

      description =
        @meeting
        |> Map.merge(%{organizer_user_id: organiser.id, meeting_type_id: nil})
        |> CalendarEventBuilder.build_event_description()

      # Quick add leaves no meeting type behind, and the note on such a booking
      # was written by the host — not by the attendee it would otherwise credit.
      assert description =~ "Nachricht vom Veranstalter:"
      refute description =~ "Nachricht vom Teilnehmer:"
    end

    test "names the attendee on a booking made through a booking page" do
      organiser = insert(:user, locale: "de")
      meeting_type = insert(:meeting_type, user: organiser)

      description =
        @meeting
        |> Map.merge(%{organizer_user_id: organiser.id, meeting_type_id: meeting_type.id})
        |> CalendarEventBuilder.build_event_description()

      assert description =~ "Nachricht vom Teilnehmer:"
      refute description =~ "Nachricht vom Veranstalter:"
    end
  end

  describe "build_event_data/1" do
    test "carries the translated description into the event" do
      organiser = insert(:user, locale: "de")

      event =
        @meeting
        |> Map.put(:organizer_user_id, organiser.id)
        |> CalendarEventBuilder.build_event_data()

      assert event.description =~ "Teilnehmer: Alice <alice@example.com>"
      # The summary is the host's own title and is never translated.
      assert event.summary == "Team Sync"
    end
  end
end
