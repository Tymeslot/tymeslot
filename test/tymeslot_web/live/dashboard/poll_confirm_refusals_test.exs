defmodule TymeslotWeb.Dashboard.PollConfirmRefusalsTest do
  @moduledoc """
  Confirming a poll's time from the host's results panel when the poll does
  not settle as plainly as `PollResultsTest` covers: the host answered their
  own poll, only the host did, or the time began while the page was open.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :polls
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Meetings
  alias Tymeslot.Polls
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  defp log_in(conn, user) do
    conn |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)
  end

  describe "confirming a time" do
    setup %{conn: conn} do
      TestMocks.setup_calendar_mocks(events: [])

      user = insert(:user, onboarding_completed_at: DateTime.utc_now())
      insert(:profile, user: user, username: "resulthost", timezone: "Europe/Tallinn")
      insert(:calendar_integration, user: user, is_active: true)

      {:ok, conn: log_in(conn, user), user: user}
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

    test "confirming a poll the host answered first books the next voter, not the host", %{
      conn: conn,
      user: user
    } do
      %{poll: poll, slot1: slot1} = open_poll_with_votes(user)

      # The host's own answers, given before anyone else's.
      host =
        insert(:poll_participant,
          poll: poll,
          name: "Host",
          email: user.email,
          inserted_at: DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:second)
        )

      insert(:poll_vote, participant: host, time_slot: slot1, response: :yes)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      select_poll(view, poll)

      html =
        view
        |> element("#poll-slot-#{slot1.id} button[phx-click='confirm_slot']")
        |> render_click()

      assert html =~ "This poll is confirmed"

      {:ok, reloaded} = Polls.get_poll_for_host(poll.id, user.id)
      assert {:ok, meeting} = Meetings.get_meeting(reloaded.confirmed_meeting_id)
      assert meeting.attendee_email == "alice@example.com"
    end

    test "confirming a poll only the host answered says there is nobody to invite", %{
      conn: conn,
      user: user
    } do
      poll =
        insert(:poll, user: user, status: :open, timezone: "Europe/Tallinn", meeting_type_id: nil)

      base = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)

      slot =
        insert(:poll_time_slot,
          poll: poll,
          start_time: base,
          end_time: DateTime.add(base, 1, :hour)
        )

      host = insert(:poll_participant, poll: poll, name: "Host", email: user.email)
      insert(:poll_vote, participant: host, time_slot: slot, response: :yes)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      select_poll(view, poll)

      view
      |> element("#poll-slot-#{slot.id} button[phx-click='confirm_slot']")
      |> render_click()

      assert render(view) =~ "Nobody but you has joined this poll yet"

      {:ok, reloaded} = Polls.get_poll_for_host(poll.id, user.id)
      assert reloaded.status == :open
    end

    test "confirming a time that began while the page was open says so on the slot", %{
      conn: conn,
      user: user
    } do
      %{poll: poll, slot1: slot1} = open_poll_with_votes(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      select_poll(view, poll)

      past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)
      slot1 |> Changeset.change(start_time: past) |> Repo.update!()

      view
      |> element("#poll-slot-#{slot1.id} button[phx-click='confirm_slot']")
      |> render_click()

      assert view |> element("#poll-slot-#{slot1.id}") |> render() =~
               "This time has already begun."

      {:ok, reloaded} = Polls.get_poll_for_host(poll.id, user.id)
      assert reloaded.status == :open
    end
  end
end
