defmodule Tymeslot.Workers.PollManagementEmailsTest do
  @moduledoc """
  Covers the poll emails that follow the host's changes: reminders kept to the
  deadline they were scheduled for, news of added times, and the cancellation.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :emails

  import Swoosh.TestAssertions
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Emails.EmailScheduler.PollScheduler
  alias Tymeslot.Emails.Shared.MjmlEmail
  alias Tymeslot.Jobs
  alias Tymeslot.Polls
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker

  setup :set_swoosh_global

  setup do
    user = insert(:user)
    _profile = insert(:profile, user: user, username: "hostname")
    deadline = DateTime.add(DateTime.utc_now(:second), 3, :day)

    poll =
      insert(:poll,
        user: user,
        status: :open,
        title: "Team sync",
        timezone: "Etc/UTC",
        deadline_at: deadline
      )

    slot = insert(:poll_time_slot, poll: poll, start_time: ~U[2030-03-04 10:00:00Z])
    %{user: user, poll: poll, slot: slot, deadline: deadline}
  end

  describe "deadline reminders" do
    test "go out for the deadline they were scheduled for", ctx do
      insert_invitee(ctx.poll, email: "ada@example.com")

      assert :ok = perform_job(EmailWorker, reminder_args(ctx.poll, ctx.deadline))

      assert_receive {:email, %{to: [{_name, "ada@example.com"}]}}, 1000
    end

    test "a reminder queued before jobs carried their deadline still goes out", ctx do
      insert_invitee(ctx.poll, email: "ada@example.com")

      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_poll_deadline_reminders",
                 "poll_id" => ctx.poll.id,
                 "reminder_value" => 1,
                 "reminder_unit" => "days"
               })

      assert_receive {:email, %{to: [{_name, "ada@example.com"}]}}, 1000
    end

    test "are dropped once the host moved the deadline", ctx do
      insert_invitee(ctx.poll, email: "ada@example.com")
      moved = DateTime.add(ctx.deadline, 1, :day)
      Repo.update!(Changeset.change(ctx.poll, deadline_at: moved))

      assert {:discard, "poll deadline changed"} =
               perform_job(EmailWorker, reminder_args(ctx.poll, ctx.deadline))

      refute_receive {:email, _any}, 200
    end

    test "are dropped once the host removed the deadline", ctx do
      Repo.update!(Changeset.change(ctx.poll, deadline_at: nil))

      assert {:discard, "poll deadline changed"} =
               perform_job(EmailWorker, reminder_args(ctx.poll, ctx.deadline))
    end
  end

  describe "send_poll_new_times" do
    test "tells everyone who has voted about only the new times, with their link", ctx do
      voted = insert(:poll_participant, poll: ctx.poll, voted_at: DateTime.utc_now(:second))
      _not_yet = insert(:poll_participant, poll: ctx.poll, email: "later@example.com")

      added =
        insert(:poll_time_slot,
          poll: ctx.poll,
          start_time: ~U[2030-03-05 15:00:00Z],
          end_time: ~U[2030-03-05 16:00:00Z],
          position: 1
        )

      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_poll_new_times",
                 "poll_id" => ctx.poll.id,
                 "slot_ids" => [added.id]
               })

      assert_receive {:email, email}, 1000
      assert email.to == [{voted.name, voted.email}]
      assert email.subject =~ "Team sync"
      assert email.text_body =~ "/hostname/poll/#{ctx.poll.token}?p=#{voted.token}"
      assert email.text_body =~ "5 March 2030"
      refute email.text_body =~ "4 March 2030"
      refute_receive {:email, _second}, 200
    end
  end

  describe "send_poll_cancelled" do
    test "tells every participant that the poll will not go ahead", ctx do
      insert_invitee(ctx.poll, email: "ada@example.com")
      insert(:poll_participant, poll: ctx.poll, email: "grace@example.com")

      assert {:ok, _cancelled} = Polls.cancel_poll(ctx.poll.id, ctx.user.id)

      assert :ok =
               perform_job(EmailWorker, cancellation_args(ctx.poll))

      assert_receive {:email, first}, 1000
      assert_receive {:email, second}, 1000
      assert first.subject =~ "Team sync"

      assert Enum.sort(Enum.flat_map([first, second], &Enum.map(&1.to, fn {_n, a} -> a end))) ==
               ["ada@example.com", "grace@example.com"]
    end

    test "still emails everyone from a job queued before it carried the host", ctx do
      insert_invitee(ctx.poll, email: "ada@example.com")
      insert(:poll_participant, poll: ctx.poll, email: "grace@example.com")
      assert {:ok, _cancelled} = Polls.cancel_poll(ctx.poll.id, ctx.user.id)

      # The shape the job had before it carried the host and the title: the
      # poll id alone, read from the cancelled poll that still exists.
      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_poll_cancelled",
                 "poll_id" => ctx.poll.id
               })

      assert_receive {:email, first}, 1000
      assert_receive {:email, second}, 1000

      assert Enum.sort(Enum.flat_map([first, second], &Enum.map(&1.to, fn {_n, a} -> a end))) ==
               ["ada@example.com", "grace@example.com"]
    end

    test "invites a reply only when the reply reaches the host", ctx do
      insert_invitee(ctx.poll, email: "ada@example.com")
      assert {:ok, _cancelled} = Polls.cancel_poll(ctx.poll.id, ctx.user.id)

      assert :ok =
               perform_job(EmailWorker, cancellation_args(ctx.poll))

      assert_receive {:email, email}, 1000
      assert {_name, host_email} = email.reply_to
      assert host_email == ctx.user.email
      assert email.text_body =~ "your reply goes straight to"

      # A host whose address is the instance's own sender gets no Reply-To, so
      # a reply would never reach them and the email does not ask for one.
      Repo.update!(Changeset.change(ctx.user, email: MjmlEmail.fetch_from_email()))
      other = insert(:poll, user: ctx.user, status: :open, title: "Second")
      insert(:poll_participant, poll: other, email: "grace@example.com")
      assert {:ok, _cancelled} = Polls.cancel_poll(other.id, ctx.user.id)

      assert :ok =
               perform_job(EmailWorker, cancellation_args(other))

      assert_receive {:email, quiet}, 1000
      assert quiet.reply_to == nil
      refute quiet.text_body =~ "reply"
    end

    test "still reaches every participant of a poll deleted straight after", ctx do
      insert(:poll_participant, poll: ctx.poll, email: "ada@example.com")
      insert(:poll_participant, poll: ctx.poll, email: "grace@example.com")

      assert {:ok, _cancelled} = Polls.cancel_poll(ctx.poll.id, ctx.user.id)
      args = cancellation_args(ctx.poll)
      assert :ok = Polls.delete_poll(ctx.poll.id, ctx.user.id)

      assert args == cancellation_args(ctx.poll)
      assert :ok = perform_job(EmailWorker, args)

      assert_receive {:email, first}, 1000
      assert_receive {:email, second}, 1000
      assert first.subject =~ "Team sync"
      assert first.from |> elem(1) |> is_binary()

      assert Enum.sort(Enum.flat_map([first, second], &Enum.map(&1.to, fn {_n, a} -> a end))) ==
               ["ada@example.com", "grace@example.com"]
    end

    test "a job queued before cancellations carried their recipients is dropped once the poll is gone",
         ctx do
      assert {:ok, _cancelled} = Polls.cancel_poll(ctx.poll.id, ctx.user.id)
      assert :ok = Polls.delete_poll(ctx.poll.id, ctx.user.id)

      assert {:discard, "poll not found"} =
               perform_job(EmailWorker, %{
                 "action" => "send_poll_cancelled",
                 "poll_id" => ctx.poll.id
               })
    end

    test "is dropped for a host whose account has gone since", ctx do
      insert(:poll_participant, poll: ctx.poll, email: "ada@example.com")
      assert {:ok, _cancelled} = Polls.cancel_poll(ctx.poll.id, ctx.user.id)
      args = Map.put(cancellation_args(ctx.poll), "user_id", ctx.user.id + 1_000_000)

      assert {:discard, "poll host not found"} = perform_job(EmailWorker, args)
      refute_receive {:email, _any}, 200
    end

    test "is cleared with the rest of the host's jobs when their account is deleted", ctx do
      insert(:poll_participant, poll: ctx.poll, email: "ada@example.com")
      assert {:ok, _cancelled} = Polls.cancel_poll(ctx.poll.id, ctx.user.id)

      Jobs.delete_pending_account_jobs(ctx.user.id, [])

      refute_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_poll_cancelled", "poll_id" => ctx.poll.id}
      )
    end
  end

  # The cancellation job `cancel_poll/2` really enqueued, as the worker
  # would receive it.
  defp cancellation_args(poll) do
    assert [%{args: args}] =
             all_enqueued(
               worker: EmailWorker,
               args: %{"action" => "send_poll_cancelled", "poll_id" => poll.id}
             )

    args
  end

  # Someone the host invited who has not voted: who the reminders are for.
  defp insert_invitee(poll, attrs) do
    now = DateTime.utc_now(:second)

    insert(
      :poll_participant,
      Keyword.merge(
        [poll: poll, invited_at: now, confirmed_at: now, link_sent_at: now, voted_at: nil],
        attrs
      )
    )
  end

  defp reminder_args(poll, deadline) do
    %{
      "action" => "send_poll_deadline_reminders",
      "poll_id" => poll.id,
      "deadline_at" => PollScheduler.deadline_arg(deadline),
      "reminder_value" => 1,
      "reminder_unit" => "days"
    }
  end
end
