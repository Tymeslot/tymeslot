defmodule TymeslotWeb.Dashboard.PollsTest do
  use TymeslotWeb.LiveCase, async: false

  @moduletag :polls
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Meetings
  alias Tymeslot.Polls
  alias Tymeslot.Polls.Confirm
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  # A host with a profile but no calendar integration and no username: the
  # baseline for list/create/validation tests.
  defp setup_host(_context) do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    profile = insert(:profile, user: user)
    {:ok, conn: log_in(build_conn(), user), user: user, profile: profile}
  end

  defp log_in(conn, user) do
    conn |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)
  end

  # ===========================================================================
  # Listing
  # ===========================================================================

  describe "Poll list" do
    setup :setup_host

    test "lists existing polls with their titles and status", %{conn: conn, user: user} do
      open_poll = insert(:poll, user: user, title: "Team sync", status: :open)
      base = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)
      insert(:poll_time_slot, poll: open_poll, start_time: base)
      insert(:poll_time_slot, poll: open_poll, start_time: DateTime.add(base, 1, :hour))
      insert(:poll, user: user, title: "Roadmap review", status: :confirmed)

      {:ok, _view, html} = live(conn, ~p"/dashboard/polls")

      assert html =~ "Team sync"
      assert html =~ "Roadmap review"
      assert html =~ "Open"
      assert html =~ "Confirmed"
      assert html =~ "2 time options"
    end

    test "shows an empty state when the user has no polls", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/polls")

      assert html =~ "No polls yet"
    end

    test "does not list polls belonging to other users", %{conn: conn} do
      other = insert(:user)
      insert(:poll, user: other, title: "Someone else's poll")

      {:ok, _view, html} = live(conn, ~p"/dashboard/polls")

      refute html =~ "Someone else's poll"
    end
  end

  # ===========================================================================
  # Creating
  # ===========================================================================

  describe "Creating a poll" do
    setup :setup_host

    test "creates a poll with candidate slots and shows it in the list", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")

      view |> element("button", "New poll") |> render_click()

      # Two candidate-slot rows.
      view |> element("button", "Add time") |> render_click()
      view |> element("button", "Add time") |> render_click()

      date = Date.utc_today() |> Date.add(7) |> Date.to_iso8601()

      view
      |> form("form[phx-submit='create_poll']", %{
        "poll" => %{
          "title" => "Launch planning",
          "duration" => "30",
          "timezone" => "Europe/Tallinn",
          "slots" => %{"0" => "#{date}T09:00", "1" => "#{date}T10:00"}
        }
      })
      |> render_submit()

      assert render(view) =~ "Launch planning"

      assert [poll] = Polls.list_polls(user.id)
      assert poll.title == "Launch planning"
      assert length(poll.time_slots) == 2
    end

    test "shows an error and creates nothing when submitted with no slots", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")

      view |> element("button", "New poll") |> render_click()

      html =
        view
        |> form("form[phx-submit='create_poll']", %{
          "poll" => %{
            "title" => "Empty poll",
            "duration" => "30",
            "timezone" => "Europe/Tallinn"
          }
        })
        |> render_submit()

      assert html =~ "Add at least one candidate time"
      assert Polls.list_polls(user.id) == []
    end
  end

  # ===========================================================================
  # Share link gating
  # ===========================================================================

  describe "Share link" do
    test "is disabled with a connect-calendar tooltip when the host has no calendar", %{
      conn: conn
    } do
      user = insert(:user, onboarding_completed_at: DateTime.utc_now())
      insert(:profile, user: user, username: "hostwithout")
      insert(:poll, user: user, title: "Needs a calendar")

      {:ok, _view, html} = live(log_in(conn, user), ~p"/dashboard/polls")

      assert html =~ "Connect a calendar in Calendar settings to enable this feature"
      refute html =~ ~s(phx-hook="CopyOnClick")
    end

    test "is enabled when the host has an active calendar integration", %{conn: conn} do
      user = insert(:user, onboarding_completed_at: DateTime.utc_now())
      insert(:profile, user: user, username: "hostwith")
      insert(:calendar_integration, user: user, is_active: true)
      poll = insert(:poll, user: user, title: "Ready to share")

      {:ok, _view, html} = live(log_in(conn, user), ~p"/dashboard/polls")

      assert html =~ ~s(phx-hook="CopyOnClick")
      assert html =~ "/hostwith/poll/#{poll.token}"
    end
  end

  # ===========================================================================
  # Availability suggestions
  # ===========================================================================

  describe "Suggested times" do
    setup %{conn: conn} do
      TestMocks.setup_calendar_mocks(events: [])

      user = insert(:user, onboarding_completed_at: DateTime.utc_now())

      profile =
        insert(:profile,
          user: user,
          username: "suggesthost",
          timezone: "Europe/Tallinn",
          buffer_minutes: 0,
          min_advance_hours: 0,
          advance_booking_days: 90
        )

      Enum.each(1..7, fn day_of_week ->
        insert(:weekly_availability,
          profile: profile,
          day_of_week: day_of_week,
          is_available: true,
          start_time: ~T[09:00:00],
          end_time: ~T[17:00:00]
        )
      end)

      insert(:calendar_integration, user: user, is_active: true)

      {:ok, conn: log_in(conn, user), user: user, profile: profile}
    end

    test "renders clickable time chips and adds a slot when one is clicked", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")

      view |> element("button", "New poll") |> render_click()

      date = Date.utc_today() |> Date.add(3) |> Date.to_iso8601()

      view
      |> form("form[phx-submit='suggest_times']", %{"date" => date})
      |> render_submit()

      assert has_element?(view, "button[phx-click='add_suggested_slot']")
      # Availability chips are display-formatted 12-hour times.
      assert has_element?(view, "button[phx-value-time='9:00 AM']")

      view |> element("button[phx-value-time='9:00 AM']") |> render_click()

      assert has_element?(view, "input[type='datetime-local'][value='#{date}T09:00']")
    end
  end

  # ===========================================================================
  # Results grid, confirmation and cancellation
  # ===========================================================================

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

    test "selecting a poll renders the grid with participant columns and vote marks", %{
      conn: conn,
      user: user
    } do
      %{poll: poll, slot1: slot1, slot2: slot2, alice: alice, bob: bob} =
        open_poll_with_votes(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      html = select_poll(view, poll)

      # Participants render as column headers.
      assert html =~ "Alice"
      assert html =~ "Bob"

      # Each cell carries the participant's response for that slot.
      assert has_element?(
               view,
               "#poll-slot-#{slot1.id} td[data-participant='#{alice.id}'][data-response='yes']"
             )

      assert has_element?(
               view,
               "#poll-slot-#{slot2.id} td[data-participant='#{alice.id}'][data-response='no']"
             )

      assert has_element?(
               view,
               "#poll-slot-#{slot1.id} td[data-participant='#{bob.id}'][data-response='if_need_be']"
             )
    end

    test "renders per-slot tally counts for a poll with mixed votes", %{conn: conn, user: user} do
      %{poll: poll, slot1: slot1, slot2: slot2} = open_poll_with_votes(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      select_poll(view, poll)

      # slot1: 1 yes, 1 if need be, 0 no.
      assert has_element?(view, "#poll-slot-#{slot1.id} [aria-label='1 Yes']")
      assert has_element?(view, "#poll-slot-#{slot1.id} [aria-label='1 If need be']")
      assert has_element?(view, "#poll-slot-#{slot1.id} [aria-label='0 No']")

      # slot2: 1 yes, 0 if need be, 1 no.
      assert has_element?(view, "#poll-slot-#{slot2.id} [aria-label='1 No']")
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

    test "cancelling a poll closes it and shows the cancelled state", %{conn: conn, user: user} do
      %{poll: poll} = open_poll_with_votes(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      select_poll(view, poll)

      html = view |> element("button[phx-click='cancel_poll']") |> render_click()

      assert html =~ "This poll was cancelled"

      {:ok, reloaded} = Polls.get_poll_for_host(poll.id, user.id)
      assert reloaded.status == :cancelled
    end

    test "live-updates the grid when a new vote is broadcast", %{conn: conn, user: user} do
      %{poll: poll, slot1: slot1} = open_poll_with_votes(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      select_poll(view, poll)

      refute render(view) =~ "Carol"

      # A guest votes: insert the vote, then broadcast as the domain does.
      carol = insert(:poll_participant, poll: poll, name: "Carol", email: "carol@example.com")
      insert(:poll_vote, participant: carol, time_slot: slot1, response: :yes)
      Polls.broadcast_update(poll.id)

      # The update routes through DashboardLive.handle_info -> send_update, which
      # applies asynchronously relative to the next render.
      wait_until(fn ->
        html = render(view)
        assert html =~ "Carol"
        # slot1 now has two yes votes (Alice + Carol).
        assert has_element?(view, "#poll-slot-#{slot1.id} [aria-label='2 Yes']")
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

      view |> element("button[phx-click='cancel_poll']") |> render_click()

      html = render(view)
      assert html =~ "This poll is no longer open"
      assert html =~ "This poll was cancelled"
    end
  end
end
