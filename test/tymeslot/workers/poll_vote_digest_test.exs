defmodule Tymeslot.Workers.PollVoteDigestTest do
  @moduledoc """
  The host's updates on new votes: which votes an update covers and when it
  marks them told, how a nudge shares that mark, and turning updates on.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :emails

  import Swoosh.TestAssertions
  import Tymeslot.ConfigTestHelpers, only: [with_config: 3]
  import Tymeslot.Factory
  import Tymeslot.Test.ClockHelpers, only: [freeze_clock: 1]
  import Tymeslot.WorkerTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.Infrastructure.CircuitBreaker
  alias Tymeslot.Infrastructure.CircuitBreakerSupervisor
  alias Tymeslot.Notifications.Email.PollEmails
  alias Tymeslot.Polls
  alias Tymeslot.Polls.Voting
  alias Tymeslot.Repo
  alias Tymeslot.Test.FailingMailerAdapter
  alias Tymeslot.Workers.EmailWorker

  # Delivery runs inside the CircuitBreaker GenServer, so Swoosh's test adapter
  # would otherwise post {:email, _} to that process. Global mode routes it to
  # the test process instead; it requires `async: false`.
  setup :set_swoosh_global

  describe "updates on new votes" do
    setup do
      user = insert(:user)
      _profile = insert(:profile, user: user)
      poll = insert(:poll, status: :open, user: user, notify_on_vote: true)
      slot = insert(:poll_time_slot, poll: poll, start_time: in_hours(48))
      {:ok, poll} = Polls.get_poll_for_voting(poll.token)
      %{user: user, poll: poll, slot: slot}
    end

    test "votes cast before the update goes out join one update a quarter hour away", ctx do
      ada = insert(:poll_participant, poll: ctx.poll)
      grace = insert(:poll_participant, poll: ctx.poll)

      {:ok, _ada_vote} = Voting.cast_votes(ctx.poll, ada.token, %{ctx.slot.id => :yes})
      {:ok, _grace_vote} = Voting.cast_votes(ctx.poll, grace.token, %{ctx.slot.id => :no})

      assert [job] = digest_jobs(ctx.poll.id)
      assert_in_delta DateTime.diff(job.scheduled_at, DateTime.utc_now()), 15 * 60, 5
    end

    test "a host whose account is about to be deleted is sent no update", ctx do
      Repo.update!(Changeset.change(ctx.user, deletion_scheduled_at: DateTime.utc_now(:second)))
      voter(ctx.poll, "Ada", DateTime.add(whole_second_now(), -600, :second))

      assert {:discard, "host account pending deletion"} = perform_digest(ctx.poll)
      refute_receive {:email, _any}, 200
    end

    test "nothing is scheduled for a poll whose host did not ask for updates", ctx do
      poll = %{ctx.poll | notify_on_vote: false}
      ada = insert(:poll_participant, poll: poll)

      {:ok, _vote} = Voting.cast_votes(poll, ada.token, %{ctx.slot.id => :yes})

      assert digest_jobs(poll.id) == []
    end

    test "the update names who voted since the last one and is then marked sent", ctx do
      long_ago = DateTime.add(DateTime.utc_now(:second), -3600, :second)

      Repo.update!(Changeset.change(ctx.poll, vote_digest_sent_at: long_ago))

      insert(:poll_participant,
        poll: ctx.poll,
        name: "Before",
        voted_at: DateTime.add(long_ago, -60, :second)
      )

      insert(:poll_participant,
        poll: ctx.poll,
        name: "Since",
        voted_at: DateTime.add(long_ago, 60, :second)
      )

      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_poll_vote_digest",
                 "poll_id" => ctx.poll.id
               })

      assert_receive {:email, email}, 1000
      assert ctx.user.email in recipients(email)
      assert email.text_body =~ "Responses from: Since"
      refute email.text_body =~ "Before"

      assert DateTime.compare(Repo.reload(ctx.poll).vote_digest_sent_at, long_ago) == :gt

      # Nothing new since: the next run sends nothing.
      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_poll_vote_digest",
                 "poll_id" => ctx.poll.id
               })

      refute_receive {:email, _again}, 200
    end

    test "sends nothing once the host has turned updates off", ctx do
      Repo.update!(Changeset.change(ctx.poll, notify_on_vote: false))
      insert(:poll_participant, poll: ctx.poll, voted_at: DateTime.utc_now(:second))

      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_poll_vote_digest",
                 "poll_id" => ctx.poll.id
               })

      refute_receive {:email, _any}, 200
    end

    test "a nudge carries the standings, so a waiting update has nothing new to tell", ctx do
      voter(ctx.poll, "Ada", DateTime.add(whole_second_now(), -300, :second))

      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_poll_host_nudge",
                 "poll_id" => ctx.poll.id,
                 "variant" => "all_voted"
               })

      assert_receive {:email, _nudge}, 1000

      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_poll_vote_digest",
                 "poll_id" => ctx.poll.id
               })

      refute_receive {:email, _digest}, 200
    end

    test "a vote that lands while an update goes out is told in the next one", ctx do
      now = whole_second_now()

      Repo.update!(
        Changeset.change(ctx.poll, vote_digest_sent_at: DateTime.add(now, -3600, :second))
      )

      voter(ctx.poll, "Early", DateTime.add(now, -600, :second))

      freeze_clock(DateTime.add(now, 500, :millisecond))
      assert :ok = perform_digest(ctx.poll)
      assert_receive {:email, first}, 1000
      assert first.text_body =~ "Responses from: Early"

      # Stamped before that update read the poll and committed after it. The
      # first is at the update's cutoff to the second: too recent to be told
      # in it, yet not to be lost to the next.
      voter(ctx.poll, "At Cutoff", DateTime.add(now, -60, :second))
      voter(ctx.poll, "Same Second", now)
      voter(ctx.poll, "In Flight", DateTime.add(now, -5, :second))

      freeze_clock(DateTime.add(now, 16 * 60, :second))
      assert :ok = perform_digest(ctx.poll)
      assert_receive {:email, second}, 1000
      assert second.text_body =~ "At Cutoff"
      assert second.text_body =~ "In Flight"
      assert second.text_body =~ "Same Second"
      refute second.text_body =~ "Early"
    end

    test "a vote too recent for an update waits for the next, which it schedules", ctx do
      now = whole_second_now()

      Repo.update!(
        Changeset.change(ctx.poll, vote_digest_sent_at: DateTime.add(now, -3600, :second))
      )

      voter(ctx.poll, "Early", DateTime.add(now, -600, :second))
      voter(ctx.poll, "Late", DateTime.add(now, -10, :second))

      freeze_clock(now)
      assert :ok = perform_digest(ctx.poll)
      assert_receive {:email, first}, 1000
      assert first.text_body =~ "Responses from: Early"
      refute first.text_body =~ "Late"
      assert [_next] = digest_jobs(ctx.poll.id)

      freeze_clock(DateTime.add(now, 16 * 60, :second))
      assert :ok = perform_digest(ctx.poll)
      assert_receive {:email, second}, 1000
      assert second.text_body =~ "Responses from: Late"
    end

    test "a rerun after the update went out marks the cutoff that update was written to",
         ctx do
      now = whole_second_now()
      since = DateTime.add(now, -3600, :second)
      Repo.update!(Changeset.change(ctx.poll, vote_digest_sent_at: since))
      voter(ctx.poll, "Early", DateTime.add(now, -600, :second))

      job =
        persisted_job(EmailWorker, %{
          "action" => "send_poll_vote_digest",
          "poll_id" => ctx.poll.id
        })

      freeze_clock(now)
      assert :ok = EmailWorker.perform(job)
      assert_receive {:email, _first}, 1000

      # The node stopped after the send and before the update was marked, and
      # someone voted before the job was rescued.
      Repo.update!(Changeset.change(Repo.reload(ctx.poll), vote_digest_sent_at: since))
      voter(ctx.poll, "Meanwhile", DateTime.add(now, 300, :second))

      freeze_clock(DateTime.add(now, 600, :second))
      assert :ok = EmailWorker.perform(job)
      refute_receive {:email, _again}, 200

      assert DateTime.compare(
               Repo.reload(ctx.poll).vote_digest_sent_at,
               DateTime.add(now, -60, :second)
             ) == :eq

      freeze_clock(DateTime.add(now, 26 * 60, :second))
      assert :ok = perform_digest(ctx.poll)
      assert_receive {:email, next}, 1000
      assert next.text_body =~ "Responses from: Meanwhile"
    end

    test "an update never moves the host's mark back", ctx do
      now = whole_second_now()
      # An update has gone out since this job's cutoff was remembered.
      later = DateTime.add(now, -30, :second)
      Repo.update!(Changeset.change(ctx.poll, vote_digest_sent_at: later))

      freeze_clock(now)

      assert :ok =
               PollEmails.handle_host_nudge(
                 %{"poll_id" => ctx.poll.id, "variant" => "all_voted"},
                 nil
               )

      assert_receive {:email, _nudge}, 1000
      assert DateTime.compare(Repo.reload(ctx.poll).vote_digest_sent_at, later) == :eq
    end

    test "a nudge that fails to send leaves its votes to the update", ctx do
      with_config(:tymeslot, Tymeslot.Mailer, adapter: FailingMailerAdapter)
      breaker = CircuitBreakerSupervisor.email_breaker_name()
      CircuitBreaker.reset(breaker)
      on_exit(fn -> CircuitBreaker.reset(breaker) end)

      since = DateTime.add(whole_second_now(), -3600, :second)
      Repo.update!(Changeset.change(ctx.poll, vote_digest_sent_at: since))
      voter(ctx.poll, "Ada", DateTime.add(whole_second_now(), -600, :second))

      assert {:error, _reason} =
               PollEmails.handle_host_nudge(
                 %{"poll_id" => ctx.poll.id, "variant" => "all_voted"},
                 nil
               )

      assert DateTime.compare(Repo.reload(ctx.poll).vote_digest_sent_at, since) == :eq
    end

    test "turning updates on reports only the votes cast from then on", ctx do
      Repo.update!(Changeset.change(ctx.poll, notify_on_vote: false, vote_digest_sent_at: nil))
      now = whole_second_now()
      voter(ctx.poll, "Before", DateTime.add(now, -600, :second))

      freeze_clock(now)

      assert {:ok, _poll} =
               Polls.update_details(ctx.poll.id, ctx.user.id, %{notify_on_vote: true})

      voter(ctx.poll, "After", DateTime.add(now, 120, :second))

      freeze_clock(DateTime.add(now, 16 * 60, :second))
      assert :ok = perform_digest(ctx.poll)
      assert_receive {:email, email}, 1000
      assert email.text_body =~ "Responses from: After"
      refute email.text_body =~ "Before"
    end
  end

  defp in_hours(hours) do
    DateTime.utc_now() |> DateTime.add(hours * 3600, :second) |> DateTime.truncate(:second)
  end

  defp digest_jobs(poll_id) do
    Enum.filter(
      all_enqueued(worker: EmailWorker),
      &(&1.args["action"] == "send_poll_vote_digest" and &1.args["poll_id"] == poll_id)
    )
  end

  defp recipients(email), do: Enum.map(email.to, fn {_name, address} -> address end)

  # A participant who saved responses at `voted_at`, confirmed by doing so.
  defp voter(poll, name, voted_at),
    do:
      insert(:poll_participant,
        poll: poll,
        name: name,
        voted_at: voted_at,
        confirmed_at: voted_at
      )

  defp perform_digest(poll),
    do: perform_job(EmailWorker, %{"action" => "send_poll_vote_digest", "poll_id" => poll.id})

  defp whole_second_now, do: DateTime.utc_now(:second)
end
