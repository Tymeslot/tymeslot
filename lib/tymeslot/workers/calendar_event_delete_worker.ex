defmodule Tymeslot.Workers.CalendarEventDeleteWorker do
  @moduledoc """
  Runs a delete scheduled from the calendar once its undo window has passed
  (see `Tymeslot.CalendarGrid.ScheduledDelete`). One attempt: a delete the
  calendar refused is either queued for the next sync by the delete itself
  or reported back as failed, never retried blindly.
  """

  use Oban.Worker, queue: :calendar_events, max_attempts: 1

  alias Tymeslot.CalendarGrid.ScheduledDelete

  @impl Oban.Worker
  def perform(%Oban.Job{id: id, args: args}), do: ScheduledDelete.perform(id, args)
end
