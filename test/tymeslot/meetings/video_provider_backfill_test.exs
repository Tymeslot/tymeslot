defmodule Tymeslot.Meetings.VideoProviderBackfillTest do
  @moduledoc """
  Tests that the video_provider backfill recovers the provider both from a
  surviving integration link and from the join URL of a row whose link was
  already severed by a disconnect.

  Exercises the SQL from 20260805125809_add_video_provider_to_meetings against
  the data shapes an existing installation can hold.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :meetings
  @moduletag :database

  import Tymeslot.MeetingTestHelpers

  alias Tymeslot.Repo

  @from_integration_sql """
  UPDATE meetings m
  SET video_provider = v.provider
  FROM video_integrations v
  WHERE m.video_integration_id = v.id
    AND m.video_provider IS NULL
  """

  @from_url_sql """
  UPDATE meetings
  SET video_provider = CASE
    WHEN COALESCE(organizer_video_url, meeting_url, '') LIKE '%zoom.us%' THEN 'zoom'
    WHEN COALESCE(organizer_video_url, meeting_url, '') LIKE '%meet.google.com%' THEN 'google_meet'
    WHEN COALESCE(organizer_video_url, meeting_url, '') LIKE '%teams.microsoft.com%' THEN 'teams'
    WHEN COALESCE(organizer_video_url, meeting_url, '') LIKE '%teams.live.com%' THEN 'teams'
  END
  WHERE video_provider IS NULL
    AND video_room_id IS NOT NULL
  """

  test "recovers the provider from a surviving integration link" do
    %{user: user} = create_user_with_profile()
    integration = insert(:video_integration, user: user, provider: "zoom")

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        video_integration_id: integration.id,
        video_room_id: "111",
        video_provider: nil
      )

    run_backfill()

    assert Repo.reload!(meeting).video_provider == "zoom"
  end

  test "recovers the provider from the join URL when the link is already gone" do
    %{user: user} = create_user_with_profile()

    # A unique index forbids two confirmed meetings for the same organiser at the
    # same time, so each row needs its own slot.
    zoom =
      insert_orphan(user, 1,
        video_room_id: "86360699337",
        organizer_video_url: "https://us05web.zoom.us/j/86360699337"
      )

    meet =
      insert_orphan(user, 2,
        video_room_id: "abc-defg-hij",
        organizer_video_url: nil,
        meeting_url: "https://meet.google.com/abc-defg-hij"
      )

    teams =
      insert_orphan(user, 3,
        video_room_id: "19:meeting_abc",
        organizer_video_url: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc"
      )

    run_backfill()

    assert Repo.reload!(zoom).video_provider == "zoom"
    assert Repo.reload!(meet).video_provider == "google_meet"
    assert Repo.reload!(teams).video_provider == "teams"
  end

  test "leaves meetings that never had a video room alone" do
    %{user: user} = create_user_with_profile()

    roomless =
      insert(:meeting,
        organizer_user_id: user.id,
        video_integration_id: nil,
        video_room_id: nil,
        video_provider: nil
      )

    run_backfill()

    assert Repo.reload!(roomless).video_provider == nil
  end

  test "leaves an unrecognisable join URL null rather than guessing" do
    %{user: user} = create_user_with_profile()

    self_hosted =
      insert(:meeting,
        organizer_user_id: user.id,
        video_integration_id: nil,
        video_room_id: "room-1",
        video_provider: nil,
        organizer_video_url: "https://video.example.com/room-1"
      )

    run_backfill()

    assert Repo.reload!(self_hosted).video_provider == nil
  end

  defp run_backfill do
    Repo.query!(@from_integration_sql)
    Repo.query!(@from_url_sql)
  end

  defp insert_orphan(user, hours_out, attrs) do
    start_time =
      DateTime.utc_now() |> DateTime.add(hours_out, :hour) |> DateTime.truncate(:second)

    insert(
      :meeting,
      Keyword.merge(
        [
          organizer_user_id: user.id,
          video_integration_id: nil,
          video_provider: nil,
          start_time: start_time,
          end_time: DateTime.add(start_time, 30, :minute)
        ],
        attrs
      )
    )
  end
end
