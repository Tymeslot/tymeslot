defmodule Tymeslot.Emails.PollPlaceTest do
  @moduledoc """
  The emails a poll's participants get name where the meeting will be held,
  so they can tell before voting whether they could come at all.
  """
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  import Tymeslot.Factory

  alias Tymeslot.Emails.Templates.{PollDeadlineReminder, PollInvitation, PollParticipantLink}
  alias Tymeslot.Repo

  @url "https://tymeslot.app/p/vote-token-123"

  defp poll(attrs) do
    user = insert(:user)
    insert(:profile, user: user)

    poll =
      insert(
        :poll,
        Keyword.merge(
          [
            user: user,
            title: "Board dinner",
            deadline_at: DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)
          ],
          attrs
        )
      )

    insert(:poll_time_slot, poll: poll)
    Repo.preload(poll, [:time_slots, user: :profile], force: true)
  end

  defp participant(poll, locale \\ "en"),
    do: insert(:poll_participant, poll: poll, email: "dana@example.com", locale: locale)

  defp renders(poll, participant) do
    [
      PollInvitation.render(poll, participant, @url),
      PollParticipantLink.render(poll, participant, @url),
      PollDeadlineReminder.render(poll, participant, @url)
    ]
  end

  test "each names the place the host typed in, in both bodies" do
    poll = poll(location_kind: :custom, location_details: "Garden pavilion")

    for email <- renders(poll, participant(poll)) do
      assert email.html_body =~ "Where"
      assert email.html_body =~ "Garden pavilion"
      assert email.text_body =~ "Where: Garden pavilion"
    end
  end

  test "a saved venue is named with its description" do
    user = insert(:user)
    venue = insert(:venue, user: user, name: "Harbour Hall", description: "Quay 4")
    poll = poll(user: user, location_kind: :in_person, venue_id: venue.id)

    [invitation | _rest] = renders(poll, participant(poll))
    assert invitation.text_body =~ "Where: Harbour Hall (Quay 4)"
  end

  test "a video call says its link comes once a time is confirmed" do
    user = insert(:user)
    video = insert(:video_integration, user: user, is_active: true)
    poll = poll(user: user, location_kind: :video, video_integration_id: video.id)

    [invitation | _rest] = renders(poll, participant(poll))
    assert invitation.text_body =~ "Where: Video call. You get the link once a time is confirmed."
  end

  test "the meeting type's location, while the poll has none of its own" do
    user = insert(:user)
    venue = insert(:venue, user: user, name: "Studio", description: nil)
    meeting_type = insert(:meeting_type, user: user, locations: [in_person_location([venue])])
    poll = poll(user: user, meeting_type_id: meeting_type.id)

    [invitation | _rest] = renders(poll, participant(poll))
    assert invitation.text_body =~ "Where: Studio"
  end

  test "in the participant's language" do
    poll = poll(location_kind: :custom, location_details: "Garden pavilion")
    [invitation | _rest] = renders(poll, participant(poll, "de"))

    assert invitation.text_body =~ "Wo: Garden pavilion"
  end

  test "nothing about a place when the poll names none" do
    poll = poll([])

    for email <- renders(poll, participant(poll)) do
      refute email.text_body =~ "Where"
      refute email.html_body =~ "Where"
    end
  end
end
