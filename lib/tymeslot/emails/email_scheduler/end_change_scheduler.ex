defmodule Tymeslot.Emails.EmailScheduler.EndChangeScheduler do
  @moduledoc "Schedules the notices of a booking whose end the host moved in their own calendar."

  alias Tymeslot.Emails.EmailScheduler.Helpers
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Workers.EmailWorker

  # A host dragging an end several times sends one notice, with the last end.
  @end_change_settle_seconds 120

  @doc """
  Schedules the notices of a booking whose end the host moved in their own
  calendar (`Tymeslot.Notifications.Email.EndChangeEmails`). One job
  waits per meeting; a change while it waits moves it back by the settling
  delay and gives it that change's start. What each seat is told comes from
  the seat itself when the job runs, not from the job; the job carries the
  start the latest change was written against, so a meeting moved since is
  not told about its old end, and one moved and then changed again is.
  """
  @spec schedule_end_change_emails(MeetingSchema.t()) :: :ok | {:error, term()}
  def schedule_end_change_emails(%MeetingSchema{id: meeting_id, start_time: start_time}) do
    %{
      "action" => "send_end_change_emails",
      "meeting_id" => meeting_id,
      "start_time" => DateTime.to_iso8601(start_time)
    }
    |> EmailWorker.new(
      queue: :emails,
      priority: 1,
      schedule_in: @end_change_settle_seconds,
      unique: [
        period: :infinity,
        fields: [:args, :queue],
        keys: [:action, :meeting_id],
        states: [:scheduled]
      ],
      replace: [scheduled: [:scheduled_at, :args]]
    )
    |> Helpers.insert(meeting_id: meeting_id)
    |> Helpers.ok()
  end
end
