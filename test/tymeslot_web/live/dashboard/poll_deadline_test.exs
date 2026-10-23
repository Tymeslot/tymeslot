defmodule TymeslotWeb.Dashboard.PollDeadlineTest do
  @moduledoc """
  What the host sees of a poll's voting deadline: the results panel says when
  voting closes, and once the deadline has passed both the panel and the poll
  list say voting has closed rather than that it is open. A panel already open
  when the deadline passes turns closed there and then, with no reload, and
  so does the list. The deadline timer belongs to the dashboard and is
  cancelled when the host leaves the Polls section.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :polls
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory
  import Tymeslot.TestHelpers.Eventually, only: [eventually: 1]
  import Tymeslot.Test.ClockHelpers, only: [freeze_clock: 1]

  alias Ecto.Changeset
  alias Tymeslot.Repo
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

  # What the panel's own deadline timer sends. The LiveView routes it to the
  # component with `send_update`, a message to itself that can queue behind
  # the next render request, so one render first lets it land.
  defp deadline_reached(view, poll) do
    send(view.pid, {:poll_deadline_reached, poll.id})
    render(view)
  end

  # The component reports the next deadline to the LiveView in a message to
  # itself; a render queued behind it lets it land before the state is read.
  defp deadline_timer(view) do
    render(view)
    :sys.get_state(view.pid).socket.assigns[:poll_deadline_timer]
  end

  defp in_an_hour, do: DateTime.utc_now() |> DateTime.add(1, :hour) |> DateTime.truncate(:second)

  test "the dashboard arms a timer for the next deadline among the listed polls", %{
    conn: conn,
    user: user
  } do
    soon = in_an_hour()
    poll_with_deadline(user, DateTime.add(soon, 1, :day))
    poll_with_deadline(user, soon)

    {:ok, view, _html} = live(conn, ~p"/dashboard/polls")

    assert %{ref: ref, deadline: ^soon} = deadline_timer(view)
    expected_ms = DateTime.diff(soon, DateTime.utc_now(), :millisecond)
    assert_in_delta Process.read_timer(ref), expected_ms, 2_000
  end

  test "the timer follows the poll on screen, not its stale copy in the list", %{
    conn: conn,
    user: user
  } do
    poll = poll_with_deadline(user, in_an_hour())
    view = open_results(conn, poll)
    later = DateTime.add(poll.deadline_at, 1, :day)

    # A live update refreshes only the poll on screen; its list copy keeps
    # the old deadline.
    poll |> Changeset.change(deadline_at: later) |> Repo.update!()
    send(view.pid, {:poll_updated, poll.id})

    # The update reaches the timer in several hops (the component reloads,
    # then reports its next deadline back), so wait for it to land.
    eventually(fn -> assert %{deadline: ^later} = deadline_timer(view) end)
  end

  describe "when the host leaves the Polls section" do
    setup %{conn: conn, user: user} do
      poll = poll_with_deadline(user, in_an_hour())
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      %{ref: ref} = deadline_timer(view)

      render_patch(view, ~p"/dashboard/settings")
      {:ok, view: view, poll: poll, ref: ref}
    end

    test "the deadline timer is cancelled", %{view: view, ref: ref} do
      assert Process.read_timer(ref) == false
      assert deadline_timer(view) == nil
    end

    test "a deadline message that was already on its way is dropped", %{
      view: view,
      poll: poll
    } do
      send(view.pid, {:poll_deadline_reached, poll.id})
      send(view.pid, {:poll_deadline_next, {poll.id, poll.deadline_at}})

      assert deadline_timer(view) == nil
      assert Process.alive?(view.pid)
    end
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

  describe "when the deadline passes with the results panel open" do
    setup %{conn: conn, user: user} do
      deadline = DateTime.utc_now() |> DateTime.add(1, :hour) |> DateTime.truncate(:second)
      poll = poll_with_deadline(user, deadline)
      insert(:poll_participant, poll: poll, name: "Grace")
      view = open_results(conn, poll)

      assert has_element?(view, "[data-testid='poll-state-banner']", "Voting is open")
      assert has_element?(view, "[data-testid='poll-invite-form']")
      {:ok, view: view, poll: poll, deadline: deadline}
    end

    test "the panel and the list turn to voting closed without a reload", %{
      view: view,
      poll: poll,
      deadline: deadline
    } do
      # The LiveView reads the clock this test freezes.
      freeze_clock(DateTime.add(deadline, 1, :second))
      deadline_reached(view, poll)

      assert has_element?(view, "[data-testid='poll-state-banner']", "Voting has closed")
      assert has_element?(view, "[data-testid='poll-deadline']", "Voting closed")
      assert has_element?(view, "[data-testid='poll-invite-closed']")
      refute has_element?(view, "[data-testid='poll-invite-form']")
      assert has_element?(view, "[data-testid='poll-status']", "Voting closed")
    end

    test "a deadline the host moved later keeps voting open past the old one", %{
      view: view,
      poll: poll,
      deadline: deadline
    } do
      # Moved without a broadcast, so only the reload on waking can see it.
      # 10:00 UTC in January is 12:00 in Tallinn (EET, UTC+2).
      poll |> Changeset.change(deadline_at: ~U[2099-01-15 10:00:00Z]) |> Repo.update!()

      freeze_clock(DateTime.add(deadline, 1, :second))
      deadline_reached(view, poll)

      assert has_element?(view, "[data-testid='poll-state-banner']", "Voting is open")
      assert has_element?(view, "[data-testid='poll-invite-form']")
      assert has_element?(view, "[data-testid='poll-status']", "Open")
      assert has_element?(view, "[data-testid='poll-deadline']", "Voting closes 15 January 2099")
      assert has_element?(view, "[data-testid='poll-deadline']", "12:00")
    end
  end

  describe "when a listed poll that is not on screen reaches its deadline" do
    setup %{conn: conn, user: user} do
      shown = poll_with_deadline(user, DateTime.add(in_an_hour(), 1, :day))
      insert(:poll_participant, poll: shown, name: "Grace", voted_at: DateTime.utc_now(:second))
      closing = poll_with_deadline(user, in_an_hour())

      view = open_results(conn, shown)
      view |> element("button[phx-click='toggle_slot_voters']") |> render_click()
      view |> element("button[phx-click='edit_poll_details']") |> render_click()

      assert has_element?(view, "button[phx-click='toggle_slot_voters'][aria-expanded='true']")
      assert has_element?(view, "[data-testid='poll-editor']")
      refute has_element?(view, "[data-testid='poll-status']", "Voting closed")
      {:ok, view: view, closing: closing}
    end

    test "its list pill turns to voting closed", %{view: view, closing: closing} do
      freeze_clock(DateTime.add(closing.deadline_at, 1, :second))
      deadline_reached(view, closing)

      assert has_element?(view, "[data-testid='poll-status']", "Voting closed")
      # The poll on screen is still open, in the list and in its panel.
      assert has_element?(view, "[data-testid='poll-status']", "Open")
      assert has_element?(view, "[data-testid='poll-state-banner']", "Voting is open")
    end

    test "the expanded slot and the open editor stay as they were", %{
      view: view,
      closing: closing
    } do
      freeze_clock(DateTime.add(closing.deadline_at, 1, :second))
      deadline_reached(view, closing)

      assert has_element?(view, "button[phx-click='toggle_slot_voters'][aria-expanded='true']")
      assert has_element?(view, "[data-testid='poll-editor']")
    end
  end
end
