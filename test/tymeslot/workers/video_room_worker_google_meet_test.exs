defmodule Tymeslot.Workers.VideoRoomWorkerGoogleMeetTest do
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :integrations

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.Factory

  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Workers.VideoRoomWorker

  setup :verify_on_exit!

  @meeting_url "https://meet.google.com/abc-defg-hij"

  # Emails hand each person their role's URL while the dashboard and the ICS
  # file show `meeting_url`. For Meet all three must be the same link, or an
  # attendee not signed in to Google under their booking address is sent to a
  # sign-in page instead of the room.
  test "gives every Google Meet participant the same plain meeting link" do
    user = insert(:user)
    _profile = insert(:profile, user: user)

    integration =
      insert(:video_integration,
        user: user,
        provider: "google_meet",
        oauth_scope: "https://www.googleapis.com/auth/meetings.space.created",
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      )

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        organizer_email: user.email,
        attendee_email: "guest@example.com",
        video_integration_id: integration.id
      )

    expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
      space = %{"name" => "spaces/NgPxrxVDQF8B", "meetingUri" => @meeting_url}
      {:ok, %Req.Response{status: 200, body: Jason.encode!(space)}}
    end)

    assert :ok = perform_job(VideoRoomWorker, %{"meeting_id" => meeting.id})

    updated_meeting = Repo.get(MeetingSchema, meeting.id)
    assert updated_meeting.video_room_id == "NgPxrxVDQF8B"
    assert updated_meeting.meeting_url == @meeting_url
    assert updated_meeting.organizer_video_url == @meeting_url
    assert updated_meeting.attendee_video_url == @meeting_url
  end
end
