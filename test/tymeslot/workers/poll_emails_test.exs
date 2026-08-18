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
  import Tymeslot.Factory

  alias Tymeslot.Polls
  alias Tymeslot.Polls.Confirm
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

      poll = create_poll(user, deadline)

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

      poll = create_poll(user, deadline)

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
    test "Polls.cancel_poll/2 deletes the pending deadline jobs" do
      user = insert(:user)
      poll = create_poll(user, in_hours(48))

      assert_enqueued(worker: EmailWorker, args: %{"poll_id" => poll.id})

      assert {:ok, _cancelled} = Polls.cancel_poll(poll.id, user.id)

      assert all_enqueued(worker: EmailWorker, args: %{"poll_id" => poll.id}) == []
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
    test "enqueues exactly once when the final participant votes, even on re-submit" do
      user = insert(:user)
      poll = insert(:poll, status: :open, user: user)
      start_one = in_hours(48)
      slot_one = insert(:poll_time_slot, poll: poll, start_time: start_one)

      _slot_two =
        insert(:poll_time_slot, poll: poll, start_time: DateTime.add(start_one, 1, :hour))

      {:ok, poll} = Polls.get_poll_for_voting(poll.token)

      {:ok, alice} = Voting.register_participant(poll, %{name: "Alice", email: "a@example.com"})
      {:ok, bob} = Voting.register_participant(poll, %{name: "Bob", email: "b@example.com"})

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
  end

  # --- Handler: deadline reminders ---

  describe "send_poll_deadline_reminders" do
    test "delivers only to participants who have not voted" do
      user = insert(:user)
      _profile = insert(:profile, user: user, username: "hostname")
      poll = insert(:poll, status: :open, user: user, deadline_at: in_hours(48))

      insert(:poll_participant, poll: poll, name: "Unvoted", email: "unvoted@example.com")

      insert(:poll_participant,
        poll: poll,
        name: "Voted",
        email: "voted@example.com",
        voted_at: DateTime.utc_now(:second)
      )

      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_poll_deadline_reminders",
                 "poll_id" => poll.id
               })

      assert_receive {:email, email}, 1000
      assert "unvoted@example.com" in recipients(email)
      refute_receive {:email, _other}, 200
    end

    test "discards when the poll is not open" do
      user = insert(:user)
      _profile = insert(:profile, user: user)
      poll = insert(:poll, status: :confirmed, user: user)

      assert {:discard, "poll not open"} =
               perform_job(EmailWorker, %{
                 "action" => "send_poll_deadline_reminders",
                 "poll_id" => poll.id
               })
    end

    test "discards without delivering when the host has no username" do
      # No profile inserted for the host, so host_username/1 resolves to nil and
      # the public voting URL would be broken.
      user = insert(:user)
      poll = insert(:poll, status: :open, user: user, deadline_at: in_hours(48))
      insert(:poll_participant, poll: poll, name: "Unvoted", email: "unvoted@example.com")

      assert {:discard, "host has no username"} =
               perform_job(EmailWorker, %{
                 "action" => "send_poll_deadline_reminders",
                 "poll_id" => poll.id
               })

      refute_receive {:email, _any}, 200
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

  defp create_poll(user, deadline_at) do
    future = in_hours(72)

    attrs =
      maybe_put_deadline(
        %{
          title: "Team sync",
          duration_minutes: 30,
          timezone: "Etc/UTC",
          slots: [%{start_time: future}, %{start_time: DateTime.add(future, 1, :hour)}]
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
end
