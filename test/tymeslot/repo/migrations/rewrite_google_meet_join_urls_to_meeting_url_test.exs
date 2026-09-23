defmodule Tymeslot.Repo.Migrations.RewriteGoogleMeetJoinUrlsToMeetingUrlTest do
  @moduledoc """
  Google Meet meetings booked before the provider stopped appending
  participant details to the join link keep serving those links from the
  two per-role columns. What matters is that the repair rewrites exactly the
  Meet rows that have a plain link to fall back on, and touches nothing else:
  other providers' per-role links are real, distinct join URLs.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :meetings
  @moduletag :video
  @moduletag :migrations

  import Tymeslot.Factory

  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Test.MigrationRunner

  @version 20_260_916_134_203

  @meet_url "https://meet.google.com/abc-defg-hij"
  @meet_organizer_url @meet_url <>
                        "?authuser=host%40example.com&role=host&uname=Host+Person"
  @meet_attendee_url @meet_url <> "?authuser=guest%40example.com&uname=Guest+Person"

  defp reload(meeting), do: Repo.get!(MeetingSchema, meeting.id)

  defp meet_meeting(attrs \\ []) do
    insert(
      :meeting,
      Keyword.merge(
        [
          video_provider: "google_meet",
          video_room_id: "abc-defg-hij",
          video_room_enabled: true,
          meeting_url: @meet_url,
          organizer_video_url: @meet_organizer_url,
          attendee_video_url: @meet_attendee_url
        ],
        attrs
      )
    )
  end

  test "rewrites both per-role links of a Google Meet meeting to the plain meeting link" do
    meeting = meet_meeting()

    MigrationRunner.replay!(@version)

    updated = reload(meeting)
    assert updated.organizer_video_url == @meet_url
    assert updated.attendee_video_url == @meet_url
    assert updated.meeting_url == @meet_url
  end

  test "reaches a past meeting too, since the calendar export and webhooks re-read it" do
    start_time = DateTime.add(DateTime.utc_now(:second), -30, :day)

    meeting =
      meet_meeting(start_time: start_time, end_time: DateTime.add(start_time, 60, :minute))

    MigrationRunner.replay!(@version)

    updated = reload(meeting)
    assert updated.organizer_video_url == @meet_url
    assert updated.attendee_video_url == @meet_url
  end

  test "leaves another provider's per-participant links alone" do
    zoom =
      insert(:meeting,
        video_provider: "zoom",
        video_room_id: "123456789",
        video_room_enabled: true,
        meeting_url: "https://zoom.us/j/123456789",
        organizer_video_url: "https://zoom.us/s/123456789?zak=host-key",
        attendee_video_url: "https://zoom.us/j/123456789?pwd=guest-code"
      )

    MigrationRunner.replay!(@version)

    updated = reload(zoom)
    assert updated.organizer_video_url == "https://zoom.us/s/123456789?zak=host-key"
    assert updated.attendee_video_url == "https://zoom.us/j/123456789?pwd=guest-code"
  end

  test "leaves a Google Meet meeting with no meeting link alone" do
    without_url = meet_meeting(meeting_url: nil)
    with_blank_url = meet_meeting(meeting_url: "")

    MigrationRunner.replay!(@version)

    assert reload(without_url).organizer_video_url == @meet_organizer_url
    assert reload(without_url).attendee_video_url == @meet_attendee_url
    assert reload(with_blank_url).organizer_video_url == @meet_organizer_url
    assert reload(with_blank_url).attendee_video_url == @meet_attendee_url
  end

  test "does not touch a Google Meet meeting already carrying the plain link" do
    already_plain =
      meet_meeting(organizer_video_url: @meet_url, attendee_video_url: @meet_url)

    MigrationRunner.replay!(@version)

    assert reload(already_plain).updated_at == already_plain.updated_at
  end
end
