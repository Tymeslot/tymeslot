defmodule Tymeslot.Polls.ReminderSchedulingTest do
  @moduledoc """
  Deadline reminders go to invitees who have not voted, so a poll schedules
  them only while it has invitees: with its first invitees, at creation or
  later, and again when the host moves the deadline. A poll shared only by
  its link schedules none. The nudge telling the host the deadline has
  passed is scheduled either way.
  """
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :polls
  @moduletag :emails

  import Tymeslot.Factory

  alias Tymeslot.Polls
  alias Tymeslot.Polls.PollParticipantSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker

  setup do
    user = insert(:user)
    insert(:profile, user: user, username: "host#{System.unique_integer([:positive])}")
    insert(:calendar_integration, user: user, provider: "debug")
    %{user: user, deadline: in_days(5)}
  end

  describe "at creation" do
    test "a poll with invitees schedules its reminders and the nudge", ctx do
      poll = create_poll_for(ctx, [%{email: "ada@example.com", name: "Ada"}])

      assert reminder_times(poll.id) == [DateTime.add(ctx.deadline, -1, :day)]
      assert [_nudge] = deadline_nudges(poll.id)
    end

    test "a poll shared only by its link schedules the nudge and no reminders", ctx do
      poll = create_poll_for(ctx, [])

      assert reminder_times(poll.id) == []
      assert [_nudge] = deadline_nudges(poll.id)
    end
  end

  describe "inviting people after the poll went out" do
    test "the first invitees bring the reminders", ctx do
      poll = create_poll_for(ctx, [])

      assert {:ok, _result} =
               Polls.invite_participants(poll.id, ctx.user.id, [
                 %{email: "ada@example.com", name: nil}
               ])

      assert reminder_times(poll.id) == [DateTime.add(ctx.deadline, -1, :day)]
    end

    test "a reminder still waiting from v1.30.0 is replaced, not doubled", ctx do
      poll = create_poll_for(ctx, [])
      reminder_at = DateTime.add(ctx.deadline, -1, :day)

      # The shape v1.30.0 queued: no deadline, unique on action and poll only.
      {:ok, _legacy} =
        %{"action" => "send_poll_deadline_reminders", "poll_id" => poll.id}
        |> EmailWorker.new(queue: :emails, scheduled_at: reminder_at)
        |> Oban.insert()

      assert {:ok, _result} =
               Polls.invite_participants(poll.id, ctx.user.id, [
                 %{email: "ada@example.com", name: nil}
               ])

      assert [%{args: %{"deadline_at" => _carried}}] =
               jobs(poll.id, "send_poll_deadline_reminders")

      assert reminder_times(poll.id) == [reminder_at]
    end

    test "later invitees add no second set", ctx do
      poll = create_poll_for(ctx, [%{email: "ada@example.com", name: nil}])

      assert {:ok, _result} =
               Polls.invite_participants(poll.id, ctx.user.id, [
                 %{email: "grace@example.com", name: nil}
               ])

      assert reminder_times(poll.id) == [DateTime.add(ctx.deadline, -1, :day)]
    end
  end

  describe "moving the deadline" do
    test "reschedules the reminders of a poll with invitees", ctx do
      poll = create_poll_for(ctx, [%{email: "ada@example.com", name: nil}])
      moved = in_days(8)

      assert {:ok, _poll} =
               Polls.update_details(poll.id, ctx.user.id, %{"deadline_at" => moved})

      assert reminder_times(poll.id) == [DateTime.add(moved, -1, :day)]
    end

    test "schedules only the nudge on a poll without invitees", ctx do
      poll = create_poll_for(ctx, [])
      moved = in_days(8)

      assert {:ok, _poll} =
               Polls.update_details(poll.id, ctx.user.id, %{"deadline_at" => moved})

      assert reminder_times(poll.id) == []
      assert [%{scheduled_at: nudge_at}] = deadline_nudges(poll.id)
      assert DateTime.compare(nudge_at, moved) == :eq
    end
  end

  describe "taking someone off the poll" do
    test "cancels the reminders once the last invitee is gone", ctx do
      poll = create_poll_for(ctx, [%{email: "ada@example.com", name: nil}])
      ada = participant(poll, "ada@example.com")

      assert :ok = Polls.remove_participant(poll.id, ctx.user.id, ada.id)

      assert reminder_times(poll.id) == []
      assert [_nudge] = deadline_nudges(poll.id)
    end

    test "keeps the reminders while another invitee remains", ctx do
      poll =
        create_poll_for(ctx, [
          %{email: "ada@example.com", name: nil},
          %{email: "grace@example.com", name: nil}
        ])

      ada = participant(poll, "ada@example.com")

      assert :ok = Polls.remove_participant(poll.id, ctx.user.id, ada.id)

      assert reminder_times(poll.id) == [DateTime.add(ctx.deadline, -1, :day)]
    end
  end

  defp participant(poll, email),
    do: Repo.get_by!(PollParticipantSchema, poll_id: poll.id, email: email)

  defp create_poll_for(ctx, invitees) do
    {:ok, poll} =
      Polls.create_poll(ctx.user.id, %{
        title: "Offsite",
        duration_minutes: 30,
        timezone: "Etc/UTC",
        deadline_at: ctx.deadline,
        slots: [%{start_time: in_days(14)}],
        invitees: invitees
      })

    poll
  end

  defp in_days(days), do: DateTime.add(DateTime.utc_now(:second), days, :day)

  defp jobs(poll_id, action) do
    Enum.filter(
      all_enqueued(worker: EmailWorker, args: %{"poll_id" => poll_id}),
      &(&1.args["action"] == action)
    )
  end

  defp reminder_times(poll_id) do
    poll_id
    |> jobs("send_poll_deadline_reminders")
    |> Enum.map(&DateTime.truncate(&1.scheduled_at, :second))
    |> Enum.sort(DateTime)
  end

  defp deadline_nudges(poll_id) do
    poll_id
    |> jobs("send_poll_host_nudge")
    |> Enum.filter(&(&1.args["variant"] == "deadline_passed"))
  end
end
