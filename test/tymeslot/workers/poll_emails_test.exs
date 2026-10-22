defmodule Tymeslot.Workers.PollEmailsTest do
  @moduledoc """
  Covers the poll email pipeline end to end: scheduling deadline jobs on poll
  creation, cancelling them on confirm/cancel, the all-voted nudge on the last
  vote, and the two EmailWorker handler actions that render and deliver.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :emails

  import Swoosh.TestAssertions
  import Tymeslot.ConfigTestHelpers, only: [with_config: 3]
  import Tymeslot.Factory
  import Tymeslot.WorkerTestHelpers

  alias Ecto.UUID
  alias Tymeslot.Emails.Templates.PollDeadlineReminder
  alias Tymeslot.Polls
  alias Tymeslot.Polls.Confirm
  alias Tymeslot.Polls.PollParticipantQueries
  alias Tymeslot.Polls.Voting
  alias Tymeslot.Workers.EmailWorker

  # Delivery runs inside the CircuitBreaker GenServer, so Swoosh's test adapter
  # would otherwise post {:email, _} to that process. Global mode routes it to
  # the test process instead; it requires `async: false`.
  setup :set_swoosh_global

  # --- Scheduling on create ---

  describe "Polls.create_poll/2 deadline scheduling" do
    test "enqueues the reminder and the deadline nudge when the deadline is >24h out" do
      user = insert(:user)
      deadline = in_hours(48)

      poll = create_poll(user, deadline, [%{email: "ada@example.com", name: nil}])

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
    end

    test "skips the reminder but keeps the nudge when the deadline is <24h out" do
      user = insert(:user)
      deadline = in_hours(12)

      poll = create_poll(user, deadline, [%{email: "ada@example.com", name: nil}])

      refute_enqueued(
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
    end

    test "enqueues nothing when the poll has no deadline" do
      user = insert(:user)

      _poll = create_poll(user, nil)

      assert all_enqueued(worker: EmailWorker) == []
    end
  end

  # --- Cancellation of scheduled jobs ---

  describe "cancelling scheduled poll jobs" do
    test "Polls.cancel_poll/2 deletes the pending deadline jobs and tells the participants" do
      user = insert(:user)
      poll = create_poll(user, in_hours(48))

      assert_enqueued(worker: EmailWorker, args: %{"poll_id" => poll.id})

      assert {:ok, _cancelled} = Polls.cancel_poll(poll.id, user.id)

      assert [%{args: %{"action" => "send_poll_cancelled"}}] =
               all_enqueued(worker: EmailWorker, args: %{"poll_id" => poll.id})
    end

    test "Confirm.confirm/3 deletes the pending deadline jobs" do
      user = insert(:user)
      _profile = insert(:profile, user: user)
      poll = create_poll(user, in_hours(48))
      slot = List.first(poll.time_slots)

      participant = insert(:poll_participant, poll: poll, email: "voter@example.com")
      insert(:poll_vote, participant: participant, time_slot: slot, response: :yes)

      assert_enqueued(worker: EmailWorker, args: %{"poll_id" => poll.id})

      assert {:ok, _meeting} = Confirm.confirm(poll.id, slot.id, user.id)

      assert all_enqueued(worker: EmailWorker, args: %{"poll_id" => poll.id}) == []
    end
  end

  # --- All-voted nudge on the last vote ---

  describe "all-voted nudge" do
    test "enqueues exactly once when the last invitee votes, even on re-submit" do
      user = insert(:user)
      poll = insert(:poll, status: :open, user: user)
      start_one = in_hours(48)
      slot_one = insert(:poll_time_slot, poll: poll, start_time: start_one)

      _slot_two =
        insert(:poll_time_slot, poll: poll, start_time: DateTime.add(start_one, 1, :hour))

      {:ok, poll} = Polls.get_poll_for_voting(poll.token)

      {:ok, %{invited: [alice, bob]}} =
        Polls.invite_participants(poll.id, poll.user_id, [
          %{name: "Alice", email: "a@example.com"},
          %{name: "Bob", email: "b@example.com"}
        ])

      {:ok, _alice_vote} = Voting.cast_votes(poll, alice.token, %{slot_one.id => :yes})

      refute_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_poll_host_nudge",
          "poll_id" => poll.id,
          "variant" => "all_voted"
        }
      )

      {:ok, _bob_vote} = Voting.cast_votes(poll, bob.token, %{slot_one.id => :yes})

      assert enqueued_all_voted_count(poll.id) == 1

      # Re-submitting a vote must not enqueue a second nudge.
      {:ok, _resubmit} = Voting.cast_votes(poll, bob.token, %{slot_one.id => :no})

      assert enqueued_all_voted_count(poll.id) == 1
    end

    test "a link request still open holds the nudge back, an expired one does not" do
      user = insert(:user)
      poll = insert(:poll, status: :open, user: user)
      slot = insert(:poll_time_slot, poll: poll, start_time: in_hours(48))
      {:ok, poll} = Polls.get_poll_for_voting(poll.token)

      _expired =
        insert(:poll_participant,
          poll: poll,
          confirmed_at: nil,
          inserted_at: DateTime.add(DateTime.utc_now(:second), -3, :day),
          link_sent_at: DateTime.add(DateTime.utc_now(:second), -3, :day)
        )

      pending = request(poll, %{name: "Bob", email: "b@example.com"})

      {:ok, %{invited: [alice]}} =
        Polls.invite_participants(poll.id, poll.user_id, [
          %{name: "Alice", email: "a@example.com"}
        ])

      {:ok, _alice_vote} = Voting.cast_votes(poll, alice.token, %{slot.id => :yes})
      assert enqueued_all_voted_count(poll.id) == 0

      # The expired request never voted: the nudge did not wait for it.
      {:ok, _bob_vote} = Voting.cast_votes(poll, pending.token, %{slot.id => :yes})
      assert enqueued_all_voted_count(poll.id) == 1
    end

    test "a poll shared only by link never claims everyone has voted" do
      user = insert(:user)
      poll = insert(:poll, status: :open, user: user)
      slot = insert(:poll_time_slot, poll: poll, start_time: in_hours(48))
      {:ok, poll} = Polls.get_poll_for_voting(poll.token)

      alice = request(poll, %{name: "Alice", email: "a@example.com"})
      {:ok, _alice_vote} = Voting.cast_votes(poll, alice.token, %{slot.id => :yes})

      assert enqueued_all_voted_count(poll.id) == 0
    end
  end

  # --- Handler: participant link ---

  describe "send_poll_participant_link" do
    test "emails the participant their personal link, addressed to no one but them" do
      user = insert(:user)
      _profile = insert(:profile, user: user, username: "hostname")
      poll = insert(:poll, status: :open, user: user, title: "Team sync")

      participant =
        insert(:poll_participant,
          poll: poll,
          name: "Typed By Anyone",
          email: "ada@example.com",
          confirmed_at: nil,
          link_sent_at: DateTime.utc_now(:second)
        )

      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_poll_participant_link",
                 "participant_id" => participant.id
               })

      assert_receive {:email, email}, 1000
      assert email.to == [{"", "ada@example.com"}]
      assert email.subject =~ "Team sync"
      assert email.text_body =~ "/hostname/poll/#{poll.token}?p=#{participant.token}"
      refute email.text_body =~ "Typed By Anyone"
      refute email.html_body =~ "Typed By Anyone"
    end

    test "discards once the participant is gone" do
      assert {:discard, "poll participant not found"} =
               perform_job(EmailWorker, %{
                 "action" => "send_poll_participant_link",
                 "participant_id" => UUID.generate()
               })

      refute_receive {:email, _any}, 200
    end

    test "discards when the poll is no longer open" do
      user = insert(:user)
      _profile = insert(:profile, user: user)
      poll = insert(:poll, status: :cancelled, user: user)
      participant = insert(:poll_participant, poll: poll)

      assert {:discard, "poll not open"} =
               perform_job(EmailWorker, %{
                 "action" => "send_poll_participant_link",
                 "participant_id" => participant.id
               })

      refute_receive {:email, _any}, 200
    end

    test "discards without delivering when the host has no username" do
      poll = insert(:poll, status: :open, user: insert(:user))
      participant = insert(:poll_participant, poll: poll)

      assert {:discard, "host has no username"} =
               perform_job(EmailWorker, %{
                 "action" => "send_poll_participant_link",
                 "participant_id" => participant.id
               })

      refute_receive {:email, _any}, 200
    end
  end

  # --- Handler: vote receipt ---

  describe "send_poll_vote_receipt" do
    test "lists the participant's responses and carries their link" do
      user = insert(:user)
      _profile = insert(:profile, user: user, username: "hostname")
      poll = insert(:poll, status: :open, user: user, timezone: "Etc/UTC")
      start_time = ~U[2030-03-04 10:00:00Z]

      slot_yes =
        insert(:poll_time_slot,
          poll: poll,
          start_time: start_time,
          end_time: DateTime.add(start_time, 1, :hour)
        )

      _slot_unanswered =
        insert(:poll_time_slot,
          poll: poll,
          start_time: DateTime.add(start_time, 1, :day),
          end_time: DateTime.add(start_time, 25, :hour)
        )

      participant = insert(:poll_participant, poll: poll, name: "Ada", email: "ada@example.com")
      insert(:poll_vote, participant: participant, time_slot: slot_yes, response: :yes)

      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_poll_vote_receipt",
                 "participant_id" => participant.id
               })

      assert_receive {:email, email}, 1000
      assert "ada@example.com" in recipients(email)
      assert email.text_body =~ "/hostname/poll/#{poll.token}?p=#{participant.token}"
      assert email.text_body =~ ": Yes"
      assert email.text_body =~ ": No answer"
    end
  end

  # --- Handler: host nudge ---

  describe "send_poll_host_nudge" do
    test "delivers to the host on an open poll" do
      user = insert(:user)
      _profile = insert(:profile, user: user)
      poll = insert(:poll, status: :open, user: user)

      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_poll_host_nudge",
                 "poll_id" => poll.id,
                 "variant" => "all_voted"
               })

      assert_receive {:email, email}, 1000
      assert user.email in recipients(email)
    end

    test "is not sent to a host whose account is about to be deleted" do
      user = insert(:user, deletion_scheduled_at: DateTime.utc_now(:second))
      _profile = insert(:profile, user: user)
      poll = insert(:poll, status: :open, user: user)

      assert {:discard, "host account pending deletion"} =
               perform_job(EmailWorker, %{
                 "action" => "send_poll_host_nudge",
                 "poll_id" => poll.id,
                 "variant" => "all_voted"
               })

      refute_receive {:email, _any}, 200
    end

    test "a rescued job does not nudge the host twice" do
      user = insert(:user)
      _profile = insert(:profile, user: user)
      poll = insert(:poll, status: :open, user: user)

      job =
        persisted_job(EmailWorker, %{
          "action" => "send_poll_host_nudge",
          "poll_id" => poll.id,
          "variant" => "all_voted"
        })

      assert :ok = EmailWorker.perform(job)
      assert :ok = EmailWorker.perform(job)

      assert_receive {:email, email}, 1000
      assert user.email in recipients(email)
      refute_receive {:email, _duplicate}, 200
    end

    test "discards on a confirmed poll" do
      user = insert(:user)
      _profile = insert(:profile, user: user)
      poll = insert(:poll, status: :confirmed, user: user)

      assert {:discard, "poll not open"} =
               perform_job(EmailWorker, %{
                 "action" => "send_poll_host_nudge",
                 "poll_id" => poll.id,
                 "variant" => "deadline_passed"
               })
    end
  end

  # --- Helpers ---

  defp create_poll(user, deadline_at, invitees \\ []) do
    future = in_hours(72)

    attrs =
      maybe_put_deadline(
        %{
          title: "Team sync",
          duration_minutes: 30,
          timezone: "Etc/UTC",
          slots: [%{start_time: future}, %{start_time: DateTime.add(future, 1, :hour)}],
          invitees: invitees
        },
        deadline_at
      )

    {:ok, poll} = Polls.create_poll(user.id, attrs)
    poll
  end

  defp maybe_put_deadline(attrs, nil), do: attrs
  defp maybe_put_deadline(attrs, deadline_at), do: Map.put(attrs, :deadline_at, deadline_at)

  defp in_hours(hours) do
    DateTime.utc_now() |> DateTime.add(hours * 3600, :second) |> DateTime.truncate(:second)
  end

  defp enqueued_all_voted_count(poll_id) do
    length(
      all_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_poll_host_nudge",
          "poll_id" => poll_id,
          "variant" => "all_voted"
        }
      )
    )
  end

  defp recipients(email), do: Enum.map(email.to, fn {_name, address} -> address end)

  defp request(poll, attrs) do
    {:ok, _outcome} = Voting.request_link(poll, attrs)
    PollParticipantQueries.get_by_poll_and_email(poll.id, attrs.email)
  end

  describe "the deadline reminder's language" do
    # A participant row with no usable language falls back to the booking
    # pages' default, not to English.
    test "is the booking pages' default for a participant with none" do
      with_config(:tymeslot, :booking_default_locale, "de")
      poll = insert(:poll, title: "Sprint Planning")
      participant = insert(:poll_participant, poll: poll, locale: nil)

      email = PollDeadlineReminder.render(poll, participant, "https://example.com/p/vote")

      assert email.subject == "Erinnerung: Stimmen Sie über „Sprint Planning“ ab"
    end
  end
end
