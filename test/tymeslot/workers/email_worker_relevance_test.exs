defmodule Tymeslot.Workers.EmailWorkerRelevanceTest do
  @moduledoc """
  The email jobs dropped unsent once the moment they are about has passed
  (`Tymeslot.Emails.EmailActions.relevant?/2`).
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.Factory

  @moduletag :workers
  @moduletag :emails

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.Emails.EmailActions
  alias Tymeslot.Emails.EmailScheduler.MeetingScheduler
  alias Tymeslot.Emails.EmailScheduler.SeatScheduler
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  describe "perform/1 for an email no longer relevant" do
    # Mox is verified on exit: a send attempted here fails the test.
    test "drops a job past its relevant_until without sending, as an expected outcome" do
      meeting = insert(:meeting, start_time: DateTime.add(DateTime.utc_now(), -3, :day))

      assert {:discard, reason} =
               perform_job(EmailWorker, %{
                 "action" => "send_reminder_emails",
                 "meeting_id" => meeting.id,
                 "reminder_value" => 30,
                 "reminder_unit" => "minutes",
                 "relevant_until" => DateTime.to_iso8601(meeting.start_time)
               })

      assert reason == "No longer relevant"
      assert EmailWorker.expected_outcome?(reason)
    end

    # Every action that carries a `relevant_until`, read from the table the
    # worker checks; `Tymeslot.Emails.EmailActionsTest` pins which they are,
    # so the list cannot come up empty unnoticed. The ids name nothing, so a
    # job that got past the check would discard as "not found" instead.
    @time_bound_actions Enum.filter(EmailActions.names(), fn action ->
                          {:ok, fields} = EmailActions.required_fields(action)
                          "relevant_until" in fields
                        end)

    for action <- @time_bound_actions do
      test "drops #{action} once its moment has passed" do
        past = DateTime.add(DateTime.utc_now(), -1, :minute)

        assert {:discard, "No longer relevant"} =
                 perform_job(EmailWorker, time_bound_args(unquote(action), past))
      end
    end

    test "runs a job whose moment is still ahead" do
      ahead = DateTime.add(DateTime.utc_now(), 1, :hour)

      assert {:discard, "Meeting not found"} =
               perform_job(EmailWorker, time_bound_args("send_reminder_emails", ahead))
    end
  end

  # A reschedule request can be answered until the later of the meeting's
  # start and a week after it was made, and the start can move while the
  # email waits. The request below was made ten days ago for a meeting that
  # started yesterday, so its deadline was yesterday as queued.
  describe "a reschedule request, judged against the meeting as it stands" do
    setup do
      now = DateTime.utc_now(:second)
      requested_at = DateTime.add(now, -10, :day)
      start = DateTime.add(now, -1, :day)

      meeting =
        insert(:meeting,
          start_time: start,
          end_time: DateTime.add(start, 30, :minute),
          reschedule_requested_at: requested_at
        )

      %{meeting: meeting, now: now}
    end

    test "sends one whose start moved later after it was queued", %{meeting: meeting, now: now} do
      assert :ok =
               MeetingScheduler.schedule_reschedule_request(
                 meeting.id,
                 meeting.reschedule_requested_at
               )

      [job] = all_enqueued(worker: EmailWorker, args: %{"meeting_id" => meeting.id})

      move_start(meeting, DateTime.add(now, 2, :day))
      expect(EmailServiceMock, :send_reschedule_request, fn _meeting -> {:ok, "sent"} end)

      assert :ok = perform_job(EmailWorker, job.args)
    end

    test "drops one past its deadline as the meeting stands", %{meeting: meeting} do
      assert :ok =
               MeetingScheduler.schedule_reschedule_request(
                 meeting.id,
                 meeting.reschedule_requested_at
               )

      [job] = all_enqueued(worker: EmailWorker, args: %{"meeting_id" => meeting.id})

      assert {:discard, reason} = perform_job(EmailWorker, job.args)
      assert reason == "Reschedule request past its deadline"
      assert EmailWorker.expected_outcome?(reason)
    end

    test "drops one whose start moved earlier, past the deadline that leaves", %{
      meeting: meeting,
      now: now
    } do
      later =
        insert(:meeting,
          start_time: DateTime.add(now, 2, :day),
          end_time: DateTime.add(now, 2 * 86_400 + 1800, :second),
          reschedule_requested_at: meeting.reschedule_requested_at
        )

      assert :ok =
               MeetingScheduler.schedule_reschedule_request(
                 later.id,
                 later.reschedule_requested_at
               )

      [job] = all_enqueued(worker: EmailWorker, args: %{"meeting_id" => later.id})

      move_start(later, DateTime.add(now, -1, :day))

      assert {:discard, "Reschedule request past its deadline"} =
               perform_job(EmailWorker, job.args)
    end

    test "a participant's copy follows the meeting too", %{meeting: meeting, now: now} do
      group =
        insert(:group_meeting,
          start_time: meeting.start_time,
          end_time: meeting.end_time,
          reschedule_requested_at: meeting.reschedule_requested_at
        )

      participant = insert(:participant, meeting: group)
      requested_at = DateTime.to_iso8601(group.reschedule_requested_at)

      assert :ok =
               SeatScheduler.schedule_seat_reschedule_request(
                 group.id,
                 participant.id,
                 requested_at
               )

      [job] = all_enqueued(worker: EmailWorker, args: %{"participant_id" => participant.id})

      assert {:discard, "Reschedule request past its deadline"} =
               perform_job(EmailWorker, job.args)

      move_start(group, DateTime.add(now, 2, :day))
      expect(EmailServiceMock, :send_reschedule_request, fn _meeting -> {:ok, "sent"} end)

      assert :ok = perform_job(EmailWorker, job.args)
    end
  end

  # As a host edit or a calendar sync would leave it: the start moved, the
  # request still standing.
  defp move_start(meeting, start) do
    meeting
    |> Changeset.change(start_time: start, end_time: DateTime.add(start, 30, :minute))
    |> Repo.update!()
  end

  defp time_bound_args(action, relevant_until) do
    {:ok, fields} = EmailActions.required_fields(action)

    fields
    |> Map.new(&{&1, placeholder(&1)})
    |> Map.merge(%{
      "action" => action,
      "relevant_until" => EmailActions.relevant_until(relevant_until)
    })
  end

  defp placeholder("reminder_value"), do: 30
  defp placeholder("reminder_unit"), do: "minutes"
  defp placeholder("variant"), do: "expired"
  defp placeholder(_id), do: UUID.generate()
end
