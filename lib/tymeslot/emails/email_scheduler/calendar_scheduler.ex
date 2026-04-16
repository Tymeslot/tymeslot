defmodule Tymeslot.Emails.EmailScheduler.CalendarScheduler do
  @moduledoc "Schedules calendar invitation and event update notification emails via Oban."

  alias Ecto.Changeset
  alias Tymeslot.Emails.EmailScheduler.Helpers
  alias Tymeslot.Workers.EmailWorker

  require Logger

  @doc """
  Schedules a calendar invitation email with high priority.

  Takes a map with atom keys containing event details and the organiser's user ID.
  DateTimes are passed as ISO 8601 strings for JSON serialisation.
  """
  @spec schedule_calendar_invitation(map()) :: :ok | {:error, String.t()}
  def schedule_calendar_invitation(params) do
    method = Map.get(params, :method, :request)
    sequence = Map.get(params, :sequence)

    result =
      %{
        "action" => "send_calendar_invitation",
        "user_id" => params.user_id,
        "attendee_email" => params.attendee_email,
        "event_title" => params.event_title,
        "event_uid" => params.event_uid,
        "event_start_at" => params.event_start_at,
        "event_end_at" => params.event_end_at,
        "event_location" => params[:event_location],
        "event_description" => params[:event_description],
        "method" => Atom.to_string(method),
        "sequence" => sequence
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
      |> Oban.insert()

    case result do
      {:ok, _job} ->
        Logger.info("Calendar invitation email job scheduled",
          user_id: params.user_id,
          attendee_email: params.attendee_email,
          event_uid: params.event_uid
        )

        :ok

      {:error, %Changeset{errors: [unique: _details]}} ->
        Logger.info("Calendar invitation email job already exists, skipping duplicate",
          attendee_email: params.attendee_email,
          event_uid: params.event_uid
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule calendar invitation email",
          user_id: params.user_id,
          error: Helpers.format_insert_error(reason)
        )

        {:error, "Failed to schedule job"}
    end
  end

  @doc """
  Schedules an event update notification with a 2-minute delay.

  Uses Oban uniqueness (keyed on action + event_uid, 5-minute period) to
  coalesce rapid edits into a single notification.
  """
  @spec schedule_event_update_notification(map()) :: :ok | {:error, String.t()}
  def schedule_event_update_notification(params) do
    method = Map.get(params, :method, :request)
    sequence = Map.get(params, :sequence)

    result =
      %{
        "action" => "send_event_update_notification",
        "user_id" => params.user_id,
        "event_uid" => params.event_uid,
        "integration_id" => params.integration_id,
        "attendee_emails" => params.attendee_emails,
        "before_title" => params.before_title,
        "before_location" => params.before_location,
        "before_description" => params.before_description,
        "before_start_at" =>
          params.before_start_at && DateTime.to_iso8601(params.before_start_at),
        "before_end_at" => params.before_end_at && DateTime.to_iso8601(params.before_end_at),
        "method" => Atom.to_string(method),
        "sequence" => sequence
      }
      |> EmailWorker.new(
        queue: :emails,
        priority: 1,
        scheduled_at: DateTime.add(DateTime.utc_now(), 120, :second),
        unique: [
          period: 300,
          fields: [:args, :queue],
          keys: [:action, :event_uid, :method]
        ]
      )
      |> Oban.insert()

    case result do
      {:ok, _job} ->
        Logger.info("Event update notification job scheduled",
          event_uid: params.event_uid,
          scheduled_in: "2 minutes"
        )

        :ok

      {:error, %Changeset{errors: [unique: _details]}} ->
        Logger.info("Event update notification job already pending, coalescing",
          event_uid: params.event_uid
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule event update notification",
          event_uid: params.event_uid,
          error: Helpers.format_insert_error(reason)
        )

        {:error, "Failed to schedule job"}
    end
  end
end
