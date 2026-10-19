defmodule Tymeslot.Emails.EmailScheduler.CalendarScheduler do
  @moduledoc "Schedules calendar invitation and event update notification emails via Oban."

  alias Tymeslot.Emails.EmailScheduler.Helpers
  alias Tymeslot.Workers.EmailWorker

  @doc """
  Schedules a calendar invitation email with high priority.

  Takes a map with atom keys containing event details and the organiser's user ID.
  DateTimes are passed as ISO 8601 strings for JSON serialisation. An all-day
  event passes `all_day: true` with ISO 8601 `event_start_date` and exclusive
  `event_end_date` instead of the two instants, which it does not have.

  `method: :cancel` makes it a cancellation instead, and `series: true` a
  cancellation of every occurrence of a recurring event. The job carries all
  it says, so it does not depend on the event still being cached when it
  runs.
  """
  @spec schedule_calendar_invitation(map()) :: :ok | {:error, term()}
  def schedule_calendar_invitation(params) do
    method = Map.get(params, :method, :request)
    sequence = Map.get(params, :sequence)

    %{
      "action" => "send_calendar_invitation",
      "user_id" => params.user_id,
      "attendee_email" => params.attendee_email,
      "event_title" => params.event_title,
      "event_uid" => params.event_uid,
      "event_start_at" => params.event_start_at,
      "event_end_at" => params.event_end_at,
      "event_all_day" => Map.get(params, :all_day, false),
      "event_start_date" => params[:event_start_date],
      "event_end_date" => params[:event_end_date],
      "event_location" => params[:event_location],
      "event_description" => params[:event_description],
      "method" => Atom.to_string(method),
      "sequence" => sequence,
      "event_series" => Map.get(params, :series, false)
    }
    |> EmailWorker.new(
      queue: :emails,
      priority: 0,
      unique: [
        period: 300,
        fields: [:args, :queue],
        keys: [:action, :attendee_email, :event_uid, :method]
      ]
    )
    |> Helpers.insert(user_id: params.user_id, event_uid: params.event_uid)
    |> Helpers.ok()
  end

  @doc """
  Schedules an event update notification, sent at once.

  Rapid edits are coalesced before this is called, by the attendee
  notification worker's own debounce
  (`Tymeslot.Meetings.AttendeeNotifications.Dispatcher`), which calls this
  once per change it decided to announce. So the job is neither delayed nor
  unique here: a second debounce, or a uniqueness window that also matched
  completed jobs, swallowed a later edit announced within minutes of the
  first.

  `before_start_date`/`before_end_date` are the ISO 8601 dates of an all-day
  baseline. `first_notification: true` marks an event that was never
  notified before, whose `before_*` values are therefore unknown rather than
  empty; the handler states the current details instead of diffing.

  `event`, the event as the update left it (string keys, ISO 8601 values),
  makes the job carry everything it says, like an invitation: the handler
  describes that instead of reading the cached event, which a write to a
  whole series drops. Such a job is sent at once and never coalesced, since
  the organiser confirmed that one change; `series` (`:following` or `:all`)
  says how much of the series it changed.
  """
  @spec schedule_event_update_notification(map()) :: :ok | {:error, term()}
  def schedule_event_update_notification(params) do
    method = Map.get(params, :method, :request)
    sequence = Map.get(params, :sequence)

    %{
      "action" => "send_event_update_notification",
      "user_id" => params.user_id,
      "event_uid" => params.event_uid,
      "integration_id" => params.integration_id,
      "attendee_emails" => params.attendee_emails,
      "before_title" => params.before_title,
      "before_location" => params.before_location,
      "before_description" => params.before_description,
      "before_start_at" => params.before_start_at && DateTime.to_iso8601(params.before_start_at),
      "before_end_at" => params.before_end_at && DateTime.to_iso8601(params.before_end_at),
      "before_start_date" => params[:before_start_date],
      "before_end_date" => params[:before_end_date],
      "first_notification" => Map.get(params, :first_notification, false),
      "method" => Atom.to_string(method),
      "sequence" => sequence
    }
    |> Map.merge(snapshot_args(params))
    |> EmailWorker.new(queue: :emails, priority: 1)
    |> Helpers.insert(event_uid: params.event_uid)
    |> Helpers.ok()
  end

  defp snapshot_args(%{event: %{} = event, series: series}) when series in [:following, :all],
    do: %{"event" => event, "series" => Atom.to_string(series)}

  defp snapshot_args(_params), do: %{}
end
