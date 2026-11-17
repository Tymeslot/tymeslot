defmodule Tymeslot.Workers.CalendarEventDeleteWorker do
  @moduledoc """
  Runs a delete scheduled from the calendar once its undo window has passed
  (see `Tymeslot.CalendarGrid.ScheduledDelete`). A delete the calendar
  refused is either queued for the next sync by the delete itself, or
  reported back as failed. Only a failure that may pass (a timeout, a server
  error) is retried, up to three attempts, and a rate limit snoozes.
  """

  use Oban.Worker, queue: :calendar_events, max_attempts: 3

  alias Tymeslot.CalendarGrid.ScheduledDelete

  @impl Oban.Worker
  def perform(%Oban.Job{} = job), do: ScheduledDelete.perform(job)
end
