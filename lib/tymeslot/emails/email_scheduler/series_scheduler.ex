defmodule Tymeslot.Emails.EmailScheduler.SeriesScheduler do
  @moduledoc """
  Schedules the emails a booking series sends as one: its confirmation, the
  cancellation of several of its sessions, and, for a series held for
  approval, its request, the host's reminder of it, and the answer when it
  is declined or expires
  (`Tymeslot.Notifications.Email.SeriesEmails`).
  """

  alias Tymeslot.Emails.EmailActions
  alias Tymeslot.Emails.EmailScheduler.Helpers
  alias Tymeslot.Workers.EmailWorker

  # An email a series sends once in its life: a completed job counts too,
  # for as long as Oban keeps it (the Pruner removes completed jobs after a
  # week, and nothing schedules these that late).
  @once_per_series [
    period: :infinity,
    fields: [:args, :queue],
    keys: [:action, :series_id],
    states: [:suspended, :available, :scheduled, :executing, :retryable, :completed]
  ]

  @doc """
  Schedules the series confirmation to its booker and organiser, now. One
  per series: a completed job counts too, while Oban keeps it (a week), so
  an announcement job run again (rescued after a node stopped mid-run)
  cannot queue a second confirmation once the first has gone out.
  """
  @spec schedule_series_confirmation_emails(binary()) :: :ok | {:error, term()}
  def schedule_series_confirmation_emails(series_id) do
    %{"action" => "send_series_confirmation", "series_id" => series_id}
    |> EmailWorker.new(queue: :emails, priority: 0, unique: @once_per_series)
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

  @doc """
  Schedules the request a series held for approval sends, now: the host's,
  to approve or decline it, and the booker's acknowledgement. One per series
  ever, as for the confirmation: a series is requested once. Dropped unsent
  past `relevant_until`, the shared approval deadline.
  """
  @spec schedule_series_request_emails(binary(), DateTime.t() | nil) :: :ok | {:error, term()}
  def schedule_series_request_emails(series_id, relevant_until) do
    %{
      "action" => "send_series_request",
      "series_id" => series_id,
      "relevant_until" => EmailActions.relevant_until(relevant_until)
    }
    |> EmailWorker.new(queue: :emails, priority: 0, unique: @once_per_series)
    |> Helpers.insert(series_id: series_id)
    |> Helpers.ok()
  end

  @doc """
  Schedules the host's reminder of a series request they have not answered,
  at `send_at`. One per series ever; the email itself is skipped when the
  request was answered or withdrawn by then, or `relevant_until` (the
  approval deadline) has passed.
  """
  @spec schedule_series_request_nudge(binary(), DateTime.t(), DateTime.t() | nil) ::
          :ok | {:error, term()}
  def schedule_series_request_nudge(series_id, %DateTime{} = send_at, relevant_until) do
    %{
      "action" => "send_series_request_nudge",
      "series_id" => series_id,
      "relevant_until" => EmailActions.relevant_until(relevant_until)
    }
    |> EmailWorker.new(
      queue: :emails,
      priority: 1,
      scheduled_at: send_at,
      unique: @once_per_series
    )
    |> Helpers.insert(series_id: series_id)
    |> Helpers.ok()
  end

  @doc """
  Schedules the booker's email saying their series request was declined or
  expired, now. One per series ever: a series is answered once.
  `relevant_until` is `nil` for a decline, which is owed however late.
  """
  @spec schedule_series_request_outcome(binary(), :declined | :expired, DateTime.t() | nil) ::
          :ok | {:error, term()}
  def schedule_series_request_outcome(series_id, variant, relevant_until)
      when variant in [:declined, :expired] do
    %{
      "action" => "send_series_request_outcome",
      "series_id" => series_id,
      "variant" => Atom.to_string(variant),
      "relevant_until" => EmailActions.relevant_until(relevant_until)
    }
    |> EmailWorker.new(queue: :emails, priority: 0, unique: @once_per_series)
    |> Helpers.insert(series_id: series_id)
    |> Helpers.ok()
  end
end
