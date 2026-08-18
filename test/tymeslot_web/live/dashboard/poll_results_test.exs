defmodule TymeslotWeb.Dashboard.PollResultsTest do
  @moduledoc """
  Covers the host's results panel for a single poll: the per-slot aggregate it
  leads with, the "who voted" disclosure behind it, confirming a time, and
  cancelling the poll.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :polls
  @moduletag :live

  import Ecto, only: [assoc: 2]
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Meetings
  alias Tymeslot.Polls
  alias Tymeslot.Polls.Confirm
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  defp log_in(conn, user) do
    conn |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)
  end

  describe "Poll results" do
    setup %{conn: conn} do
      # Empty calendar by default; the conflict test re-stubs with an event.
      TestMocks.setup_calendar_mocks(events: [])

      user = insert(:user, onboarding_completed_at: DateTime.utc_now())
      profile = insert(:profile, user: user, username: "resulthost", timezone: "Europe/Tallinn")
      insert(:calendar_integration, user: user, is_active: true)

      {:ok, conn: log_in(conn, user), user: user, profile: profile}
    end

    # An open poll with two future slots and two voters with mixed responses.
    # slot1: Alice yes, Bob if_need_be. slot2: Alice no, Bob yes.
    defp open_poll_with_votes(user) do
      poll =
        insert(:poll,
          user: user,
          title: "Team offsite",
          status: :open,
          timezone: "Europe/Tallinn",
          meeting_type_id: nil
        )

      base = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)

      slot1 =
        insert(:poll_time_slot,
          poll: poll,
          start_time: base,
          end_time: DateTime.add(base, 1, :hour),
          position: 0
        )

      later = DateTime.add(base, 1, :day)

      slot2 =
        insert(:poll_time_slot,
          poll: poll,
          start_time: later,
          end_time: DateTime.add(later, 1, :hour),
          position: 1
        )

      alice = insert(:poll_participant, poll: poll, name: "Alice", email: "alice@example.com")
      bob = insert(:poll_participant, poll: poll, name: "Bob", email: "bob@example.com")

      insert(:poll_vote, participant: alice, time_slot: slot1, response: :yes)
      insert(:poll_vote, participant: alice, time_slot: slot2, response: :no)
      insert(:poll_vote, participant: bob, time_slot: slot1, response: :if_need_be)
      insert(:poll_vote, participant: bob, time_slot: slot2, response: :yes)

      %{poll: poll, slot1: slot1, slot2: slot2, alice: alice, bob: bob}
    end

    defp select_poll(view, poll) do
      view
      |> element("button[phx-click='select_poll'][phx-value-id='#{poll.id}']")
      |> render_click()
    end

    defp toggle_voters(view, slot) do
      view
      |> element("#poll-slot-#{slot.id} button[phx-click='toggle_slot_voters']")
      |> render_click()
    end

    test "selecting a poll shows the aggregate and keeps the voters collapsed", %{
      conn: conn,
      user: user
    } do
      %{poll: poll, slot1: slot1} = open_poll_with_votes(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      html = select_poll(view, poll)

      # The aggregate is what the panel leads with.
      assert html =~ "2 guests have voted so far."
      assert has_element?(view, "#poll-slot-#{slot1.id} [data-testid='poll-response-bar']")

      # Who voted which way is behind a disclosure, so no name is on screen and
      # no breakdown is rendered until the host asks for one.
      refute html =~ "Alice"
      refute html =~ "Bob"
      refute has_element?(view, "[data-testid='poll-slot-voters']")

      assert has_element?(
               view,
               "#poll-slot-#{slot1.id} button[phx-click='toggle_slot_voters'][aria-expanded='false']"
             )
    end

    test "expanding a slot reveals who voted, and collapsing hides them again", %{
      conn: conn,
      user: user
    } do
      %{poll: poll, slot1: slot1, slot2: slot2} = open_poll_with_votes(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      select_poll(view, poll)

      html = toggle_voters(view, slot1)

      # Alice said yes to slot1, Bob said "if need be" — each name sits under
      # the response it belongs to, not just anywhere on the page.
      assert has_element?(
               view,
               "#poll-voters-#{slot1.id} [data-response='yes']",
               "Alice"
             )

      assert has_element?(
               view,
               "#poll-voters-#{slot1.id} [data-response='if_need_be']",
               "Bob"
             )

      assert html =~ "Alice"

      # Expansion is per slot: the other slot stays shut.
      refute has_element?(view, "#poll-voters-#{slot2.id}")

      assert has_element?(
               view,
               "#poll-slot-#{slot1.id} button[phx-click='toggle_slot_voters'][aria-expanded='true']"
             )

      # Clicking again puts it away.
      html = toggle_voters(view, slot1)
      refute has_element?(view, "#poll-voters-#{slot1.id}")
      refute html =~ "Alice"
    end

    test "shows the host's own description and a copy-link control", %{conn: conn, user: user} do
      poll =
        insert(:poll,
          user: user,
          status: :open,
          title: "Team offsite",
          description: "Ninety minutes, whole team.",
          meeting_type_id: nil
        )

      insert(:poll_time_slot, poll: poll)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      html = select_poll(view, poll)

      assert html =~ "Ninety minutes, whole team."
      assert has_element?(view, "[data-testid='poll-description']")

      # The link belongs with the open poll, not only on the list card the
      # panel pushes off screen.
      assert has_element?(view, "#poll-results-copy-#{poll.id}[phx-hook='CopyOnClick']")
    end

    test "edits the title and description of an open poll", %{conn: conn, user: user} do
      %{poll: poll} = open_poll_with_votes(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      select_poll(view, poll)

      refute has_element?(view, "[data-testid='poll-details-form']")

      view |> element("[data-testid='poll-edit-details']") |> render_click()
      assert has_element?(view, "[data-testid='poll-details-form']")

      html =
        view
        |> form("[data-testid='poll-details-form']",
          poll: %{title: "Team offsite (moved)", description: "Now ninety minutes."}
        )
        |> render_submit()

      # Persisted, and the panel is back to its reading state showing the change.
      {:ok, reloaded} = Polls.get_poll_for_host(poll.id, user.id)
      assert reloaded.title == "Team offsite (moved)"
      assert reloaded.description == "Now ninety minutes."

      refute has_element?(view, "[data-testid='poll-details-form']")
      assert html =~ "Team offsite (moved)"
      assert html =~ "Now ninety minutes."
    end

    test "keeps the form open and reports the error when the title is blank", %{
      conn: conn,
      user: user
    } do
      %{poll: poll} = open_poll_with_votes(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      select_poll(view, poll)
      view |> element("[data-testid='poll-edit-details']") |> render_click()

      html =
        view
        |> form("[data-testid='poll-details-form']", poll: %{title: "   ", description: ""})
        |> render_submit()

      assert has_element?(view, "[data-testid='poll-details-form']")
      assert html =~ "can&#39;t be blank"

      {:ok, reloaded} = Polls.get_poll_for_host(poll.id, user.id)
      assert reloaded.title == "Team offsite"
    end

    test "offers no edit control once the poll is confirmed", %{conn: conn, user: user} do
      %{poll: poll, slot1: slot1} = open_poll_with_votes(user)
      {:ok, _meeting} = Confirm.confirm(poll.id, slot1.id, user.id)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      select_poll(view, poll)

      refute has_element?(view, "[data-testid='poll-edit-details']")
    end

    test "badges the slot leading on yes votes while the poll is open", %{
      conn: conn,
      user: user
    } do
      %{poll: poll, slot1: slot1, slot2: slot2} = open_poll_with_votes(user)

      # Both slots hold one yes, so slot1 leads on the "if need be" tiebreak.
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      select_poll(view, poll)

      assert has_element?(view, "#poll-slot-#{slot1.id} [data-testid='poll-slot-leader']")
      refute has_element?(view, "#poll-slot-#{slot2.id} [data-testid='poll-slot-leader']")
    end

    test "badges no slot when every candidate time scores the same", %{conn: conn, user: user} do
      %{poll: poll, slot1: slot1, slot2: slot2, alice: alice} = open_poll_with_votes(user)

      # Level the two slots. slot1 already holds alice=yes, bob=if_need_be;
      # flipping alice's "no" on slot2 to "if need be" leaves slot2 at
      # bob=yes, alice=if_need_be. Neither time is a better answer than the
      # other, so nothing should be badged.
      alice
      |> assoc(:votes)
      |> Repo.all()
      |> Enum.find(&(&1.poll_time_slot_id == slot2.id))
      |> Changeset.change(response: :if_need_be)
      |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      select_poll(view, poll)

      assert has_element?(
               view,
               "#poll-slot-#{slot1.id} [data-testid='poll-response-bar'][aria-label='1 Yes, 1 If need be, 0 No']"
             )

      assert has_element?(
               view,
               "#poll-slot-#{slot2.id} [data-testid='poll-response-bar'][aria-label='1 Yes, 1 If need be, 0 No']"
             )

      refute has_element?(view, "[data-testid='poll-slot-leader']")
    end

    test "badges no slot when a poll has votes from nobody", %{conn: conn, user: user} do
      poll = insert(:poll, user: user, status: :open)
      base = DateTime.truncate(DateTime.add(DateTime.utc_now(), 3, :day), :second)

      insert(:poll_time_slot,
        poll: poll,
        start_time: base,
        end_time: DateTime.add(base, 1, :hour),
        position: 0
      )

      later = DateTime.add(base, 1, :day)

      insert(:poll_time_slot,
        poll: poll,
        start_time: later,
        end_time: DateTime.add(later, 1, :hour),
        position: 1
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      html = select_poll(view, poll)

      assert html =~ "0 guests have voted so far."
      assert html =~ "No responses yet."
      refute has_element?(view, "[data-testid='poll-slot-leader']")
      refute has_element?(view, "button[phx-click='toggle_slot_voters']")
    end

    test "renders per-slot tally counts for a poll with mixed votes", %{conn: conn, user: user} do
      %{poll: poll, slot1: slot1, slot2: slot2} = open_poll_with_votes(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      select_poll(view, poll)

      # The bar's label is the whole per-slot aggregate in one string, so it
      # pins every count at once rather than three separately-passable checks.
      assert has_element?(
               view,
               "#poll-slot-#{slot1.id} [data-testid='poll-response-bar'][aria-label='1 Yes, 1 If need be, 0 No']"
             )

      assert has_element?(
               view,
               "#poll-slot-#{slot2.id} [data-testid='poll-response-bar'][aria-label='1 Yes, 0 If need be, 1 No']"
             )
    end

    test "confirming a slot mints a meeting and shows the confirmed state", %{
      conn: conn,
      user: user
    } do
      %{poll: poll, slot1: slot1} = open_poll_with_votes(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      select_poll(view, poll)

      html =
        view
        |> element("#poll-slot-#{slot1.id} button[phx-click='confirm_slot']")
        |> render_click()

      # The poll is confirmed and points at a meeting owned by the host.
      {:ok, reloaded} = Polls.get_poll_for_host(poll.id, user.id)
      assert reloaded.status == :confirmed
      assert reloaded.confirmed_meeting_id
      assert {:ok, meeting} = Meetings.get_meeting(reloaded.confirmed_meeting_id)
      assert meeting.organizer_user_id == user.id

      # The panel switches to the confirmed state and highlights the winning slot.
      assert html =~ "This poll is confirmed"
      assert has_element?(view, "#poll-slot-#{slot1.id}.bg-blue-50")
      refute has_element?(view, "button[phx-click='confirm_slot']")
    end

    test "confirming a taken slot shows an inline error and keeps the poll open", %{
      conn: conn,
      user: user
    } do
      %{poll: poll, slot1: slot1} = open_poll_with_votes(user)

      # The host already has a confirmed meeting at the slot time.
      insert(:meeting,
        organizer_user_id: user.id,
        status: "confirmed",
        start_time: slot1.start_time,
        end_time: slot1.end_time
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      select_poll(view, poll)

      html =
        view
        |> element("#poll-slot-#{slot1.id} button[phx-click='confirm_slot']")
        |> render_click()

      assert html =~ "This time is no longer free"

      {:ok, reloaded} = Polls.get_poll_for_host(poll.id, user.id)
      assert reloaded.status == :open
      assert reloaded.confirmed_meeting_id == nil
    end

    test "opening the cancel modal leaves the poll untouched until it is confirmed", %{
      conn: conn,
      user: user
    } do
      %{poll: poll} = open_poll_with_votes(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      select_poll(view, poll)

      html = view |> element("button[phx-click='request_cancel_poll']") |> render_click()

      # Cancelling is irreversible, so the destructive button must only open the
      # confirmation, never perform the cancellation.
      assert html =~ "Cancel this poll?"
      assert {:ok, %{status: :open}} = Polls.get_poll_for_host(poll.id, user.id)

      html = view |> element("button[phx-click='close_cancel_poll_modal']") |> render_click()

      refute html =~ "Cancel this poll?"
      assert {:ok, %{status: :open}} = Polls.get_poll_for_host(poll.id, user.id)
    end

    test "confirming the cancel modal closes the poll and shows the cancelled state", %{
      conn: conn,
      user: user
    } do
      %{poll: poll} = open_poll_with_votes(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      select_poll(view, poll)

      view |> element("button[phx-click='request_cancel_poll']") |> render_click()
      html = view |> element("button[phx-click='cancel_poll']") |> render_click()

      assert html =~ "This poll was cancelled"
      refute html =~ "Cancel this poll?"

      {:ok, reloaded} = Polls.get_poll_for_host(poll.id, user.id)
      assert reloaded.status == :cancelled
    end

    test "live-updates the aggregate when a new vote is broadcast", %{conn: conn, user: user} do
      %{poll: poll, slot1: slot1} = open_poll_with_votes(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      select_poll(view, poll)

      # Open the breakdown first: a live update must refresh what it shows
      # without shutting a panel the host is reading.
      toggle_voters(view, slot1)
      refute render(view) =~ "Carol"

      # A guest votes: insert the vote, then broadcast as the domain does.
      carol = insert(:poll_participant, poll: poll, name: "Carol", email: "carol@example.com")
      insert(:poll_vote, participant: carol, time_slot: slot1, response: :yes)
      Polls.broadcast_update(poll.id)

      # The update routes through DashboardLive.handle_info -> send_update, which
      # applies asynchronously relative to the next render.
      wait_until(fn ->
        # slot1 now has two yes votes (Alice + Carol) out of three guests.
        assert has_element?(
                 view,
                 "#poll-slot-#{slot1.id} [data-testid='poll-response-bar'][aria-label='2 Yes, 1 If need be, 0 No']"
               )

        assert render(view) =~ "3 guests have voted so far."
        assert has_element?(view, "#poll-voters-#{slot1.id} [data-response='yes']", "Carol")
        :ok
      end)
    end

    test "shows a conflict badge on a slot that clashes with the host calendar", %{
      conn: conn,
      user: user
    } do
      %{poll: poll, slot1: slot1, slot2: slot2} = open_poll_with_votes(user)

      # A blocking calendar event overlapping only slot1.
      TestMocks.setup_calendar_mocks(
        events: [
          %{
            summary: "Busy",
            start_time: DateTime.add(slot1.start_time, 30, :minute),
            end_time: DateTime.add(slot1.end_time, 30, :minute)
          }
        ]
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      select_poll(view, poll)

      # Slot health is computed asynchronously, so the badge appears once the
      # supervised check returns.
      wait_until(fn ->
        assert has_element?(view, "#poll-slot-#{slot1.id}", "Calendar conflict")
        refute has_element?(view, "#poll-slot-#{slot2.id}", "Calendar conflict")
        :ok
      end)
    end

    test "a confirmed poll never flags the winning slot as a calendar conflict", %{
      conn: conn,
      user: user
    } do
      %{poll: poll, slot1: slot1} = open_poll_with_votes(user)

      # Confirm the poll: this mints a meeting that lives on the host's calendar.
      {:ok, _meeting} = Confirm.confirm(poll.id, slot1.id, user.id)

      # The calendar now reports a clash at the winning slot (the poll's own
      # meeting), but a closed poll must not run slot health at all.
      TestMocks.setup_calendar_mocks(
        events: [
          %{summary: "Confirmed", start_time: slot1.start_time, end_time: slot1.end_time}
        ]
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      select_poll(view, poll)

      assert has_element?(view, "#poll-slot-#{slot1.id}", "Winner")
      refute has_element?(view, "#poll-slot-#{slot1.id}", "Calendar conflict")
      refute has_element?(view, "p", "Checking your calendar")
    end

    test "confirming an already-closed poll reports it and refreshes the panel", %{
      conn: conn,
      user: user
    } do
      %{poll: poll, slot1: slot1} = open_poll_with_votes(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      select_poll(view, poll)

      # The poll closes without the on-screen panel being notified (stale render).
      poll |> Changeset.change(status: :confirmed) |> Repo.update!()

      view
      |> element("#poll-slot-#{slot1.id} button[phx-click='confirm_slot']")
      |> render_click()

      html = render(view)
      assert html =~ "This poll is no longer open"
      assert html =~ "This poll is confirmed"
    end

    test "cancelling an already-closed poll reports it and refreshes the panel", %{
      conn: conn,
      user: user
    } do
      %{poll: poll} = open_poll_with_votes(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      select_poll(view, poll)

      poll |> Changeset.change(status: :cancelled) |> Repo.update!()

      view |> element("button[phx-click='request_cancel_poll']") |> render_click()
      view |> element("button[phx-click='cancel_poll']") |> render_click()

      html = render(view)
      assert html =~ "This poll is no longer open"
      assert html =~ "This poll was cancelled"
    end
  end
end
