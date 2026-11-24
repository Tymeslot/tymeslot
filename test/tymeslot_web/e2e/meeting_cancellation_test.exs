defmodule TymeslotWeb.E2E.MeetingCancellationTest do
  use TymeslotWeb.BrowserCase, async: false

  alias Tymeslot.Profiles

  @moduletag :e2e
  @moduletag :meetings

  test "guest cancels a meeting via the cancellation link", %{session: session} do
    user = create_onboarded_user()
    profile = Profiles.get_profile(user.id)

    meeting =
      insert(:meeting, %{
        organizer_user: user,
        organizer_user_id: user.id,
        status: :confirmed
      })

    session =
      session
      |> visit("/#{profile.username}/meeting/#{meeting.uid}/cancel")
      |> assert_has(by_css("[data-testid='cancel-meeting']"))
      |> click(by_css("[data-testid='cancel-meeting']"))

    # Should show cancellation confirmed page
    assert_has(session, filter(by_css("h1"), has_text: "Meeting Cancelled"))
  end
end
