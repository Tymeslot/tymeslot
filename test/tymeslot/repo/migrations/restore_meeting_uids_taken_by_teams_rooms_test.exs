defmodule Tymeslot.Repo.Migrations.RestoreMeetingUidsTakenByTeamsRoomsTest do
  @moduledoc """
  Teams rooms used to overwrite a booking's `uid` with their Graph event id,
  breaking the cancel and reschedule links already emailed for it. The repair
  must give each such booking its original uid back from the link that still
  carries it, keep the overwritten event id where calendar sync can find it,
  and leave every other row exactly as it is.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :meetings
  @moduletag :video
  @moduletag :migrations

  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Test.MigrationRunner

  @version 20_260_924_083_057

  @graph_event_id "AAMkAGI2TG93AAA="
  @teams_url "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc"

  defp reload(meeting), do: Repo.get!(MeetingSchema, meeting.id)

  defp links(uid) do
    base = "https://tymeslot.example/host/meeting/#{uid}"
    [cancel_url: base <> "/cancel", reschedule_url: base <> "/reschedule"]
  end

  # A Teams booking as the old code left it: the links carry the original
  # uid, and the uid column carries the room's Graph event id.
  defp overwritten_teams_meeting(attrs \\ []) do
    original_uid = UUID.generate()

    meeting =
      insert(
        :meeting,
        [
          uid: Keyword.get(attrs, :overwritten_uid, @graph_event_id),
          video_provider: "teams",
          video_room_id: @graph_event_id,
          meeting_url: @teams_url,
          provider_event_id: nil
        ]
        |> Keyword.merge(links(original_uid))
        |> Keyword.merge(Keyword.delete(attrs, :overwritten_uid))
      )

    {meeting, original_uid}
  end

  test "restores the uid from the cancel link and keeps the event id for calendar sync" do
    {meeting, original_uid} = overwritten_teams_meeting()

    MigrationRunner.replay!(@version)

    updated = reload(meeting)
    assert updated.uid == original_uid
    assert updated.provider_event_id == @graph_event_id
  end

  test "restores the uid from the reschedule link when there is no cancel link" do
    {meeting, original_uid} = overwritten_teams_meeting(cancel_url: nil)

    MigrationRunner.replay!(@version)

    assert reload(meeting).uid == original_uid
  end

  test "keeps a calendar event id the row already has" do
    {meeting, original_uid} = overwritten_teams_meeting(provider_event_id: "AAMk-calendar-event")

    {blank, blank_uid} =
      overwritten_teams_meeting(overwritten_uid: "AAMk-other", provider_event_id: "")

    MigrationRunner.replay!(@version)

    assert %{uid: ^original_uid, provider_event_id: "AAMk-calendar-event"} = reload(meeting)
    # An empty string is no event id at all.
    assert %{uid: ^blank_uid, provider_event_id: "AAMk-other"} = reload(blank)
  end

  test "restores a row from before video_provider was recorded, found by its Teams link" do
    {teams_work, work_uid} =
      overwritten_teams_meeting(video_provider: nil, overwritten_uid: "AAMk-work")

    {teams_personal, personal_uid} =
      overwritten_teams_meeting(
        video_provider: nil,
        overwritten_uid: "AAMk-personal",
        meeting_url: "https://teams.live.com/meet/9876543210"
      )

    MigrationRunner.replay!(@version)

    assert reload(teams_work).uid == work_uid
    assert reload(teams_personal).uid == personal_uid
  end

  test "leaves a row alone when another meeting already holds its original uid" do
    {meeting, original_uid} = overwritten_teams_meeting()
    holder = insert(:meeting, uid: original_uid)

    MigrationRunner.replay!(@version)

    assert %{uid: @graph_event_id, provider_event_id: nil} = reload(meeting)
    assert reload(holder).uid == original_uid
  end

  test "leaves both rows alone when two of them claim the same original uid" do
    {first, original_uid} = overwritten_teams_meeting()

    second =
      insert(
        :meeting,
        [uid: "AAMk-second", video_provider: "teams", meeting_url: @teams_url] ++
          links(original_uid)
      )

    MigrationRunner.replay!(@version)

    assert reload(first).uid == @graph_event_id
    assert reload(second).uid == "AAMk-second"
  end

  test "leaves a row alone when neither link carries a uid" do
    {meeting, _original_uid} = overwritten_teams_meeting(cancel_url: nil, reschedule_url: nil)

    MigrationRunner.replay!(@version)

    assert %{uid: @graph_event_id, provider_event_id: nil} = reload(meeting)
  end

  test "touches neither another provider's row nor a Teams row that kept its uid" do
    other_uid = UUID.generate()

    zoom =
      insert(
        :meeting,
        [
          uid: "legacy-zoom-event-1",
          video_provider: "zoom",
          meeting_url: "https://zoom.us/j/123456789"
        ] ++ links(other_uid)
      )

    intact_uid = UUID.generate()

    intact =
      insert(
        :meeting,
        [
          uid: intact_uid,
          video_provider: "teams",
          meeting_url: @teams_url,
          provider_event_id: nil
        ] ++ links(UUID.generate())
      )

    MigrationRunner.replay!(@version)

    assert %{uid: "legacy-zoom-event-1", provider_event_id: nil} = reload(zoom)
    assert reload(zoom).updated_at == zoom.updated_at
    assert %{uid: ^intact_uid, provider_event_id: nil} = reload(intact)
    assert reload(intact).updated_at == intact.updated_at
  end

  test "is idempotent" do
    {meeting, original_uid} = overwritten_teams_meeting()

    MigrationRunner.replay!(@version)
    first = reload(meeting)

    MigrationRunner.replay!(@version)

    assert reload(meeting) == first
    assert %{uid: ^original_uid, provider_event_id: @graph_event_id} = first
  end
end
