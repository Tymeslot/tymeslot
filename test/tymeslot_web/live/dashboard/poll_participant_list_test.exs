defmodule TymeslotWeb.Dashboard.PollParticipantListTest do
  @moduledoc """
  The participant list in the poll editor as a disclosure: it opens and
  closes on the host's click, and stays open while the host works through it.
  """
  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :polls
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.TestMocks

  @toggle "[data-testid='poll-participants-toggle']"

  setup %{conn: conn} do
    TestMocks.setup_calendar_mocks(events: [])

    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    insert(:profile, user: user, username: "listhost", timezone: "Etc/UTC")
    insert(:calendar_integration, user: user, is_active: true)

    poll =
      insert(:poll,
        user: user,
        status: :open,
        timezone: "Etc/UTC",
        meeting_type_id: nil,
        deadline_at: DateTime.add(DateTime.utc_now(:second), 3, :day)
      )

    insert(:poll_time_slot, poll: poll)
    grace = insert(:poll_participant, poll: poll, name: "Grace")

    conn = conn |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    {:ok, view, _html} = live(conn, ~p"/dashboard/polls")

    view
    |> element("button[phx-click='select_poll'][phx-value-id='#{poll.id}']")
    |> render_click()

    view |> element("[data-testid='poll-edit-details']") |> render_click()
    %{view: view, poll: poll, grace: grace}
  end

  test "starts closed and opens on a click", %{view: view, poll: poll} do
    assert has_element?(view, @toggle <> "[aria-expanded='false']")
    assert has_element?(view, "#poll-participants-#{poll.id}[hidden]")

    view |> element(@toggle) |> render_click()

    assert has_element?(view, @toggle <> "[aria-expanded='true']")
    refute has_element?(view, "#poll-participants-#{poll.id}[hidden]")
  end

  test "stays open after the host sends someone their link again", %{
    view: view,
    poll: poll,
    grace: grace
  } do
    view |> element(@toggle) |> render_click()

    view
    |> element("[data-testid='poll-resend-invitation'][phx-value-id='#{grace.id}']")
    |> render_click()

    assert render(view) =~ "Sent Grace their link again."
    assert has_element?(view, @toggle <> "[aria-expanded='true']")
    refute has_element?(view, "#poll-participants-#{poll.id}[hidden]")
  end
end
