defmodule TymeslotWeb.Dashboard.PollDeadlineTest do
  @moduledoc """
  What the host sees of a poll's voting deadline: the results panel says when
  voting closes, and once the deadline has passed both the panel and the poll
  list say voting has closed rather than that it is open.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :polls
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.TestMocks

  setup %{conn: conn} do
    TestMocks.setup_calendar_mocks(events: [])
    Gettext.put_locale(TymeslotWeb.Gettext, "en")

    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    insert(:profile, user: user, username: "deadlinehost", timezone: "Europe/Tallinn")

    conn = conn |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    {:ok, conn: conn, user: user}
  end

  defp poll_with_deadline(user, deadline_at) do
    poll =
      insert(:poll,
        user: user,
        status: :open,
        timezone: "Europe/Tallinn",
        meeting_type_id: nil,
        deadline_at: deadline_at
      )

    insert(:poll_time_slot, poll: poll)
    poll
  end

  defp open_results(conn, poll) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/polls")

    view
    |> element("button[phx-click='select_poll'][phx-value-id='#{poll.id}']")
    |> render_click()

    view
  end

  test "an open poll before its deadline says voting is open and when it closes", %{
    conn: conn,
    user: user
  } do
    # 10:00 UTC in January is 12:00 in Tallinn (EET, UTC+2).
    deadline = ~U[2099-01-15 10:00:00Z]
    view = open_results(conn, poll_with_deadline(user, deadline))

    assert has_element?(view, "[data-testid='poll-state-banner']", "Voting is open")
    assert has_element?(view, "[data-testid='poll-deadline']", "Voting closes 15 January 2099")
    assert has_element?(view, "[data-testid='poll-deadline']", "12:00")
  end

  test "an open poll past its deadline says voting has closed", %{conn: conn, user: user} do
    deadline = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)
    view = open_results(conn, poll_with_deadline(user, deadline))

    assert has_element?(view, "[data-testid='poll-state-banner']", "Voting has closed")
    refute has_element?(view, "[data-testid='poll-state-banner']", "Voting is open")
    assert has_element?(view, "[data-testid='poll-deadline']", "Voting closed")
  end

  test "the poll list marks an open poll past its deadline as voting closed", %{
    conn: conn,
    user: user
  } do
    past = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)
    poll_with_deadline(user, past)

    {:ok, view, _html} = live(conn, ~p"/dashboard/polls")

    assert has_element?(view, "[data-testid='poll-status']", "Voting closed")
    refute has_element?(view, "[data-testid='poll-status']", "Open")
  end

  test "a poll without a deadline shows no deadline line", %{conn: conn, user: user} do
    view = open_results(conn, poll_with_deadline(user, nil))

    assert has_element?(view, "[data-testid='poll-state-banner']", "Voting is open")
    refute has_element?(view, "[data-testid='poll-deadline']")
  end
end
