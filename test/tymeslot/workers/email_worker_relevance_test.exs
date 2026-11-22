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

  alias Ecto.UUID
  alias Tymeslot.Emails.EmailActions
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

    # Every action that carries a `relevant_until`. The ids name nothing, so a
    # job that got past the check would discard as "not found" instead.
    @time_bound_actions [
      "send_reminder_emails",
      "send_seat_reminder",
      "send_reschedule_request",
      "send_seat_reschedule_request",
      "send_reschedule_request_unanswered",
      "send_reschedule_request_lapsed",
      "send_booking_request_emails",
      "send_booking_approval_nudge",
      "send_booking_request_outcome",
      "send_series_request",
      "send_series_request_nudge",
      "send_series_request_outcome",
      "send_poll_deadline_reminders"
    ]

    test "the list above is every action that carries a relevant_until" do
      carrying =
        Enum.filter(EmailActions.names(), fn action ->
          {:ok, fields} = EmailActions.required_fields(action)
          "relevant_until" in fields
        end)

      assert Enum.sort(carrying) == Enum.sort(@time_bound_actions)
    end

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
