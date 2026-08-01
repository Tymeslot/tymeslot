defmodule Tymeslot.Meetings.AttendeeNotificationsMigrationTest do
  @moduledoc """
  Regression: the `AddAttendeeNotificationTracking` migration's
  `jsonb_build_object` backfill must survive NULL inputs across every
  notifiable field. This test seeds rows with NULL-heavy data, runs the
  backfill SQL (identical to the migration body), and asserts that the
  resulting `last_notified_state` handles NULLs gracefully (as JSON `null`)
  rather than raising or producing `{}`.

  See docs/superpowers/specs/2026-04-15-centralise-attendee-notifications-design.md.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations

  alias Ecto.UUID
  alias Tymeslot.Repo

  @provider_calendar_events_backfill_sql """
  UPDATE provider_calendar_events SET last_notified_state = jsonb_build_object(
    'title',       COALESCE(to_jsonb(summary),     'null'::jsonb),
    'starts_at',   COALESCE(to_jsonb(start_at),    'null'::jsonb),
    'ends_at',     COALESCE(to_jsonb(end_at),      'null'::jsonb),
    'location',    COALESCE(to_jsonb(location),    'null'::jsonb),
    'description', COALESCE(to_jsonb(description), 'null'::jsonb),
    'video_link',  'null'::jsonb,
    'attendees',   COALESCE(to_jsonb(attendees),   '[]'::jsonb)
  )
  WHERE id = $1
  """

  @meetings_backfill_sql """
  UPDATE meetings SET last_notified_state = jsonb_build_object(
    'title',       COALESCE(to_jsonb(title), 'null'::jsonb),
    'starts_at',   COALESCE(to_jsonb(start_time), 'null'::jsonb),
    'ends_at',     COALESCE(to_jsonb(end_time), 'null'::jsonb),
    'location',    COALESCE(to_jsonb(location), 'null'::jsonb),
    'description', COALESCE(to_jsonb(description), 'null'::jsonb),
    'video_link',  COALESCE(to_jsonb(attendee_video_url), 'null'::jsonb),
    'attendees',   CASE
                     WHEN attendee_email IS NULL THEN '[]'::jsonb
                     ELSE jsonb_build_array(attendee_email)
                   END
  )
  WHERE id = $1::uuid
  """

  describe "provider_calendar_events backfill" do
    test "populates last_notified_state from current columns when NULLs are present" do
      event =
        insert(:provider_calendar_event,
          summary: "Test Title",
          description: nil,
          location: nil,
          attendees: [],
          ical_sequence: 0,
          last_notified_state: %{}
        )

      Repo.query!(@provider_calendar_events_backfill_sql, [event.id])

      state = reload_state("provider_calendar_events", event.id)

      assert state["title"] == "Test Title"
      assert is_nil(state["description"])
      assert is_nil(state["location"])
      assert state["attendees"] == []
      assert is_nil(state["video_link"])
      # Non-NULL timestamps take the to_jsonb branch and land as ISO-8601 strings.
      assert state["starts_at"] =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/
      assert state["ends_at"] =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/
    end

    test "preserves populated attendee list through the backfill" do
      attendees = [
        %{"email" => "a@example.com", "name" => "A"},
        %{"email" => "b@example.com", "name" => "B"}
      ]

      event =
        insert(:provider_calendar_event,
          summary: "With Attendees",
          description: "hello",
          location: "Room 1",
          attendees: attendees,
          ical_sequence: 0,
          last_notified_state: %{}
        )

      Repo.query!(@provider_calendar_events_backfill_sql, [event.id])

      state = reload_state("provider_calendar_events", event.id)

      assert state["title"] == "With Attendees"
      assert state["description"] == "hello"
      assert state["location"] == "Room 1"
      assert state["attendees"] == attendees
    end
  end

  describe "meetings backfill" do
    test "populates last_notified_state from current columns when NULLs are present" do
      # attendee_email is NOT NULL in the meetings table, so we cover the
      # nullable notifiable columns (description, location, attendee_video_url)
      # to exercise the COALESCE branches of the backfill SQL.
      meeting =
        insert(:meeting,
          title: "Meeting Title",
          description: nil,
          location: nil,
          attendee_video_url: nil,
          attendee_email: "attendee@example.com",
          ical_sequence: 0,
          last_notified_state: %{}
        )

      Repo.query!(@meetings_backfill_sql, [UUID.dump!(meeting.id)])

      state = reload_state("meetings", meeting.id)

      assert state["title"] == "Meeting Title"
      assert is_nil(state["description"])
      assert is_nil(state["location"])
      assert is_nil(state["video_link"])
      assert state["attendees"] == ["attendee@example.com"]
      # Non-NULL timestamps take the to_jsonb branch and land as ISO-8601 strings.
      assert state["starts_at"] =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/
      assert state["ends_at"] =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/
    end

    test "wraps attendee_email in a single-element JSON array" do
      meeting =
        insert(:meeting,
          title: "With Attendee",
          description: "body",
          location: "HQ",
          attendee_video_url: "https://video.example.com/room",
          attendee_email: "attendee@example.com",
          ical_sequence: 0,
          last_notified_state: %{}
        )

      Repo.query!(@meetings_backfill_sql, [UUID.dump!(meeting.id)])

      state = reload_state("meetings", meeting.id)

      assert state["title"] == "With Attendee"
      assert state["description"] == "body"
      assert state["location"] == "HQ"
      assert state["video_link"] == "https://video.example.com/room"
      assert state["attendees"] == ["attendee@example.com"]
    end
  end

  defp reload_state("meetings", id) do
    %{rows: [[state]]} =
      Repo.query!(
        "SELECT last_notified_state FROM meetings WHERE id = $1::uuid",
        [UUID.dump!(id)]
      )

    state
  end

  defp reload_state("provider_calendar_events", id) do
    %{rows: [[state]]} =
      Repo.query!(
        "SELECT last_notified_state FROM provider_calendar_events WHERE id = $1",
        [id]
      )

    state
  end
end
