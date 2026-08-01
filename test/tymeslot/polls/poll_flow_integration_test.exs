defmodule Tymeslot.Polls.PollFlowIntegrationTest do
  @moduledoc """
  End-to-end journey for meeting polls, exercising the real internal stack and
  stubbing only the external calendar boundary.

  The happy path drives registration and voting through the public voting
  LiveView (`/:username/poll/:token`) to prove the web wiring, then confirms a
  winning slot through `Polls.Confirm`. The remaining scenarios (vote editing,
  closed-poll rejection, the confirmation race, and the slot/participant caps)
  drive the domain directly where a full LiveView round-trip would add nothing.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration

  use Oban.Testing, repo: Tymeslot.Repo

  import Ecto.Query
  import Tymeslot.Factory
  import Tymeslot.ThemeBookingFlowHelpers, only: [seed_booking_account: 3]

  alias Ecto.Changeset
  alias Phoenix.ConnTest
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Meetings
  alias Tymeslot.Polls
  alias Tymeslot.Polls.Confirm
  alias Tymeslot.Polls.PollParticipantSchema
  alias Tymeslot.Polls.PollVoteSchema
  alias Tymeslot.Polls.Voting
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker

  setup do
    # Confirmation runs through the ad-hoc booking path, which checks the host's
    # calendar for conflicts — stub that external boundary for the whole module.
    TestMocks.setup_calendar_mocks()
    :ok
  end

  defp poll_path(username, token), do: "/#{username}/poll/#{token}"

  # Registers a participant and casts their votes through the public voting
  # LiveView on a fresh connection, returning the connected view.
  defp vote_via_liveview(username, token, %{name: name, email: email}, votes) do
    {:ok, view, _html} = live(ConnTest.build_conn(), poll_path(username, token))

    view
    |> form("form[data-testid='poll-register-form']", %{"name" => name, "email" => email})
    |> render_submit()

    view
    |> form("form[data-testid='poll-vote-form']", %{"votes" => votes})
    |> render_submit()

    view
  end

  defp vote_count(poll_id) do
    Repo.aggregate(
      from(v in PollVoteSchema,
        join: p in PollParticipantSchema,
        on: v.poll_participant_id == p.id,
        where: p.poll_id == ^poll_id
      ),
      :count
    )
  end

  describe "full happy path" do
    test "two participants vote through the page and the host confirms a meeting", %{conn: conn} do
      %{user: user, profile: profile} = seed_booking_account("1", "journey-host", "Etc/UTC")

      # Confirmation books onto the host's primary calendar, so promote the
      # seeded integration — that is what drives the calendar-event job below.
      integration = Repo.get_by!(CalendarIntegrationSchema, user_id: user.id)

      profile
      |> Changeset.change(primary_calendar_integration_id: integration.id)
      |> Repo.update!()

      base = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)
      deadline = DateTime.add(base, 1, :day)

      slots =
        for offset <- 0..2 do
          start_time = DateTime.add(base, offset, :hour)
          %{start_time: start_time, end_time: DateTime.add(start_time, 30, :minute)}
        end

      {:ok, poll} =
        Polls.create_poll(user.id, %{
          title: "Team offsite",
          duration_minutes: 30,
          timezone: "Etc/UTC",
          deadline_at: deadline,
          slots: slots
        })

      [slot1, slot2, slot3] = poll.time_slots

      # Both deadline jobs are scheduled at creation.
      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_poll_deadline_reminders", "poll_id" => poll.id}
      )

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_poll_host_nudge",
          "poll_id" => poll.id,
          "variant" => "deadline_passed"
        }
      )

      # The host's poll page is reachable and renders the voting shell.
      {:ok, _view, html} = live(conn, poll_path(profile.username, poll.token))
      assert html =~ "poll-voting"
      assert html =~ "Team offsite"

      # Participant one registers and votes through the public page.
      vote_via_liveview(profile.username, poll.token, %{name: "Ada", email: "ada@example.com"}, %{
        slot1.id => "yes",
        slot2.id => "if_need_be",
        slot3.id => "no"
      })

      alice = Repo.get_by!(PollParticipantSchema, poll_id: poll.id, email: "ada@example.com")
      assert %DateTime{} = alice.voted_at

      # A second participant, on a fresh connection, already sees participant
      # one's tally before casting anything — the tallies are public.
      {:ok, bob_view, _html} =
        live(ConnTest.build_conn(), poll_path(profile.username, poll.token))

      assert has_element?(bob_view, "span.poll-tally--yes .poll-tally-count", "1")

      vote_via_liveview(profile.username, poll.token, %{name: "Bob", email: "bob@example.com"}, %{
        slot1.id => "yes",
        slot2.id => "yes",
        slot3.id => "no"
      })

      bob = Repo.get_by!(PollParticipantSchema, poll_id: poll.id, email: "bob@example.com")
      assert %DateTime{} = bob.voted_at

      # Votes persisted and tallies reflect both voters on the winning slot.
      {:ok, reloaded} = Polls.get_poll_for_voting(poll.token)
      tallies = Polls.tallies(reloaded)
      assert tallies[slot1.id].yes == 2
      assert tallies[slot2.id].yes == 1
      assert tallies[slot2.id].if_need_be == 1
      assert tallies[slot3.id].no == 2

      # The host confirms the winning slot.
      assert {:ok, meeting} = Confirm.confirm(poll.id, slot1.id, user.id)

      # The meeting carries the right timing and the first available voter as the
      # primary attendee; the other voter rides along as a guest.
      assert meeting.start_time == slot1.start_time
      assert meeting.end_time == slot1.end_time
      assert meeting.organizer_user_id == user.id
      assert meeting.attendee_email == "ada@example.com"

      assert [guest] = Meetings.list_meeting_guests(meeting.id)
      assert guest.email == "bob@example.com"

      # The calendar-event job is enqueued for the newly minted meeting.
      assert_enqueued(
        worker: CalendarEventWorker,
        args: %{"action" => "create", "meeting_id" => meeting.id}
      )

      # The poll flips to confirmed and points at the meeting.
      {:ok, confirmed} = Polls.get_poll_for_host(poll.id, user.id)
      assert confirmed.status == :confirmed
      assert confirmed.confirmed_meeting_id == meeting.id

      # Confirmation cancels the pending deadline jobs.
      refute_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_poll_deadline_reminders", "poll_id" => poll.id}
      )

      refute_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_poll_host_nudge",
          "poll_id" => poll.id,
          "variant" => "deadline_passed"
        }
      )
    end
  end

  describe "vote editing" do
    test "re-casting a response replaces the prior vote rather than duplicating it" do
      %{user: user} = seed_booking_account("1", "edit-host", "Etc/UTC")
      poll = insert(:poll, user: user, status: :open)
      slot = insert(:poll_time_slot, poll: poll)

      {:ok, loaded} = Polls.get_poll_for_voting(poll.token)

      {:ok, participant} =
        Voting.register_participant(loaded, %{name: "Cy", email: "cy@example.com"})

      assert {:ok, _yes_vote} = Voting.cast_votes(loaded, participant.token, %{slot.id => "yes"})

      {:ok, after_yes} = Polls.get_poll_for_voting(poll.token)
      assert Polls.tallies(after_yes)[slot.id].yes == 1
      assert vote_count(poll.id) == 1

      assert {:ok, _no_vote} = Voting.cast_votes(loaded, participant.token, %{slot.id => "no"})

      {:ok, after_no} = Polls.get_poll_for_voting(poll.token)
      # A single row still, now flipped to "no".
      assert vote_count(poll.id) == 1
      assert Polls.tallies(after_no)[slot.id].yes == 0
      assert Polls.tallies(after_no)[slot.id].no == 1
    end
  end

  describe "closed poll rejects voting" do
    test "a confirmed poll renders the scheduled state and refuses further votes", %{conn: conn} do
      %{user: user, profile: profile} = seed_booking_account("1", "closed-host", "Etc/UTC")

      start_time = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)
      poll = insert(:poll, user: user, status: :open)

      slot =
        insert(:poll_time_slot,
          poll: poll,
          start_time: start_time,
          end_time: DateTime.add(start_time, 30, :minute)
        )

      {:ok, loaded} = Polls.get_poll_for_voting(poll.token)

      {:ok, participant} =
        Voting.register_participant(loaded, %{name: "Di", email: "di@example.com"})

      assert {:ok, _vote} = Voting.cast_votes(loaded, participant.token, %{slot.id => "yes"})

      assert {:ok, _confirmed} = Confirm.confirm(poll.id, slot.id, user.id)

      # Voting is now closed: a further cast is rejected and nothing changes.
      {:ok, closed} = Polls.get_poll_for_voting(poll.token)

      assert {:error, :voting_closed} =
               Voting.cast_votes(closed, participant.token, %{slot.id => "no"})

      assert vote_count(poll.id) == 1
      assert Polls.tallies(closed)[slot.id].yes == 1

      # The public page shows the confirmed / scheduled state.
      {:ok, _view, html} = live(conn, poll_path(profile.username, poll.token))
      assert html =~ "poll-confirmed"
      assert html =~ "Scheduled for"
    end
  end

  describe "confirmation race" do
    test "a slot taken since voting opened fails with :slot_taken and keeps the poll open" do
      %{user: user} = seed_booking_account("1", "race-host", "Etc/UTC")

      start_time = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)
      end_time = DateTime.add(start_time, 30, :minute)

      poll = insert(:poll, user: user, status: :open)
      slot = insert(:poll_time_slot, poll: poll, start_time: start_time, end_time: end_time)

      {:ok, loaded} = Polls.get_poll_for_voting(poll.token)

      {:ok, participant} =
        Voting.register_participant(loaded, %{name: "Eve", email: "eve@example.com"})

      assert {:ok, _vote} = Voting.cast_votes(loaded, participant.token, %{slot.id => "yes"})

      # The host's calendar already holds a confirmed meeting at the winning slot.
      insert(:meeting,
        organizer_user_id: user.id,
        status: "confirmed",
        start_time: start_time,
        end_time: end_time
      )

      assert {:error, :slot_taken} = Confirm.confirm(poll.id, slot.id, user.id)

      {:ok, still_open} = Polls.get_poll_for_host(poll.id, user.id)
      assert still_open.status == :open
      assert still_open.confirmed_meeting_id == nil
    end
  end

  describe "caps" do
    test "creating a poll with 41 slots is rejected" do
      %{user: user} = seed_booking_account("1", "slotcap-host", "Etc/UTC")

      base = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)

      slots =
        for offset <- 0..40 do
          start_time = DateTime.add(base, offset * 60, :minute)
          %{start_time: start_time, end_time: DateTime.add(start_time, 30, :minute)}
        end

      assert length(slots) == 41

      assert {:error, :too_many_slots} =
               Polls.create_poll(user.id, %{
                 title: "Too many options",
                 duration_minutes: 30,
                 timezone: "Etc/UTC",
                 slots: slots
               })
    end

    test "registering the 41st participant is rejected once the cap is reached" do
      %{user: user} = seed_booking_account("1", "partcap-host", "Etc/UTC")
      poll = insert(:poll, user: user, status: :open)

      for n <- 1..40 do
        insert(:poll_participant, poll: poll, email: "full-#{n}@example.com")
      end

      {:ok, loaded} = Polls.get_poll_for_voting(poll.token)

      assert {:error, :poll_full} =
               Voting.register_participant(loaded, %{name: "Overflow", email: "over@example.com"})
    end
  end
end
