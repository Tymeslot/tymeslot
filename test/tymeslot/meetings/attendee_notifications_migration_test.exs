defmodule Tymeslot.Meetings.AttendeeNotificationsMigrationTest do
  @moduledoc """
  Regression: the backfill in `20260415154744_add_attendee_notification_tracking`
  must survive NULL inputs across every notifiable field. This test seeds
  NULL-heavy rows, runs the migration itself, and asserts that the resulting
  `last_notified_state` handles NULLs gracefully (as JSON `null`) rather than
  raising or producing `{}`.

  The migration adds the tracking columns, so the round trip drops them and
  adds them back — `up` then meets the rows exactly as it did on a real
  database, and it backfills every row rather than one named id. The module is
  loaded from `priv` and run through `Ecto.Migrator`; see
  `Tymeslot.Test.MigrationRunner`.

  See docs/superpowers/specs/2026-04-15-centralise-attendee-notifications-design.md.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations

  alias Ecto.UUID
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_260_415_154_744

  describe "provider_calendar_events backfill" do
    test "populates last_notified_state from current columns when NULLs are present" do
      event =
        insert(:provider_calendar_event,
          summary: "Test Title",
          description: nil,
          location: nil,
          attendees: []
        )

      MigrationRunner.rerun!(@version)

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
          attendees: attendees
        )

      MigrationRunner.rerun!(@version)

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
          attendee_email: "attendee@example.com"
        )

      MigrationRunner.rerun!(@version)

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
          attendee_email: "attendee@example.com"
        )

      MigrationRunner.rerun!(@version)

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
