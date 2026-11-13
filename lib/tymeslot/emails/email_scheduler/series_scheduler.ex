defmodule Tymeslot.Emails.EmailScheduler.SeriesScheduler do
  @moduledoc """
  Schedules the emails a booking series sends as one: its confirmation and
  the cancellation of several of its sessions
  (`Tymeslot.Notifications.Email.SeriesEmails`).
  """

  alias Tymeslot.Emails.EmailScheduler.Helpers
  alias Tymeslot.Workers.EmailWorker

  @doc """
  Schedules the series confirmation to its booker and organiser, now. One
  per series ever: a completed job counts too, so an announcement job run
  again (rescued after a node stopped mid-run) cannot queue a second
  confirmation once the first has gone out.
  """
  @spec schedule_series_confirmation_emails(binary()) :: :ok | {:error, term()}
  def schedule_series_confirmation_emails(series_id) do
    %{"action" => "send_series_confirmation", "series_id" => series_id}
    |> EmailWorker.new(
      queue: :emails,
      priority: 0,
      unique: [
        period: :infinity,
        fields: [:args, :queue],
        keys: [:action, :series_id],
        states: [:suspended, :available, :scheduled, :executing, :retryable, :completed]
      ]
    )
    |> Helpers.insert(series_id: series_id)
    |> Helpers.ok()
  end

  @doc """
  Schedules the cancellation of the sessions `occurrence_ids` names (meeting
  or seat ids) to the series' booker and organiser, worded for whoever
  cancelled them.
  """
  @spec schedule_series_cancellation_emails(binary(), [binary()], :attendee | :organizer) ::
          {:ok, :scheduled | :duplicate} | {:error, term()}
  def schedule_series_cancellation_emails(series_id, occurrence_ids, cancelled_by)
      when cancelled_by in [:attendee, :organizer] do
    %{
      "action" => "send_series_cancellation",
      "series_id" => series_id,
      "occurrence_ids" => occurrence_ids,
      "cancelled_by" => Atom.to_string(cancelled_by)
    }
    |> EmailWorker.new(queue: :emails, priority: 0)
    |> Helpers.insert(series_id: series_id)
  end
end
