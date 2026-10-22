defmodule TymeslotWeb.Dashboard.PollsInviteClosedTest do
  @moduledoc """
  The results panel's invite form once an open poll's deadline has passed.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :polls
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.TestMocks

  defp open_results(conn, user, poll) do
    {:ok, view, _html} =
      live(
        conn |> init_test_session(%{}) |> fetch_session() |> log_in_user(user),
        ~p"/dashboard/polls"
      )

    view
    |> element("button[phx-click='select_poll'][phx-value-id='#{poll.id}']")
    |> render_click()

    view
  end

  setup %{conn: conn} do
    TestMocks.setup_calendar_mocks(events: [])
    Mox.stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _id, _from, _to ->
      {:ok, []}
    end)
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    insert(:profile, user: user)
    %{conn: conn, user: user}
  end

  test "an open poll takes invitations", %{conn: conn, user: user} do
    poll = insert(:poll, user: user, status: :open, meeting_type_id: nil)
    insert(:poll_time_slot, poll: poll)

    view = open_results(conn, user, poll)

    assert has_element?(view, "[data-testid='poll-invite-form']")
    refute has_element?(view, "[data-testid='poll-invite-closed']")
  end

  test "after the deadline the form gives way to a hint to move it", %{conn: conn, user: user} do
    past = DateTime.add(DateTime.utc_now(:second), -1, :hour)
    poll = insert(:poll, user: user, status: :open, meeting_type_id: nil, deadline_at: past)
    insert(:poll_time_slot, poll: poll)

    view = open_results(conn, user, poll)

    refute has_element?(view, "[data-testid='poll-invite-form']")

    assert has_element?(
             view,
             "[data-testid='poll-invite-closed']",
             "Voting has closed. Move the deadline in Edit poll to invite people."
           )
  end
end
