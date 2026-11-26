defmodule Tymeslot.Emails.EmailScheduler.MeetingScheduler do
  @moduledoc "Schedules meeting-related emails via Oban."

  alias Tymeslot.Emails.EmailActions
  alias Tymeslot.Emails.EmailScheduler.Helpers
  alias Tymeslot.Jobs
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.MeetingTypes.Reminders
  alias Tymeslot.Workers.EmailWorker

  require Logger

  @doc """
  Schedules confirmation emails to be sent immediately with high priority.
  """
  @spec schedule_confirmation_emails(term()) :: :ok | {:error, term()}
  def schedule_confirmation_emails(meeting_id) do
    %{"action" => "send_confirmation_emails", "meeting_id" => meeting_id}
    |> EmailWorker.new(
      queue: :emails,
      # Highest priority for confirmations
      priority: 0,
      unique: [
        # 5 minutes uniqueness window
        period: 300,
        fields: [:args, :queue],
        keys: [:action, :meeting_id]
      ]
    )
    |> Helpers.insert(meeting_id: meeting_id)
    |> Helpers.ok()
  end

  @doc """
  Schedules the invitations for guests a host added to a meeting after it was
  booked.

  The job names the guests it is for, so each addition gets a job of its own
  and no two jobs ever send to the same guest, however they overlap. A retry
  sends only to those of its guests still without `confirmation_sent_at`.
  """
  @spec schedule_guest_invitations(binary(), [binary()]) :: :ok | {:error, term()}
  def schedule_guest_invitations(meeting_id, guest_ids)
      when is_list(guest_ids) and guest_ids != [] do
    %{"action" => "send_guest_invitations", "meeting_id" => meeting_id, "guest_ids" => guest_ids}
    |> EmailWorker.new(queue: :emails, priority: 0)
    |> Helpers.insert(meeting_id: meeting_id)
    |> Helpers.ok()
  end

  @doc """
  Schedules the pair of emails a held booking produces: the invitee's
  acknowledgement and the host's request to answer.

  Both legs are attempted by the same job, but neither gates the other:
  `BookingApprovalEmails.handle_booking_request_emails/2` always tries both,
  claims each, and fails the job for a retry when one did not go out.
  `previous_start_time:` is the time a reschedule moved the booking from.
  `relevant_until:` is when the request stops mattering
  (`Tymeslot.Notifications.Relevance.approval_request/1`).

  Restricted to `:incomplete` unique states minus `:executing`, so a fast
  reschedule that calls this again for the same meeting is neither
  swallowed by the first pair's completed job nor by one still executing.

  A pending pair for the same request (identical args) swallows this one,
  so a repeated call sends nothing twice. A pending pair for an earlier
  request (another deadline or previous time: a reschedule sent the booking
  back into the gate while the first pair was waiting or retrying) is
  deleted first, as the nudge's is: left in place it would swallow this
  pair and be dropped at the old deadline, or tell both sides the old time.
  The new pair is a new job, so its legs are claimed afresh.
  """
  @spec schedule_request_emails(term(), keyword()) :: :ok | {:error, term()}
  def schedule_request_emails(meeting_id, opts) do
    args = %{
      "action" => "send_booking_request_emails",
      "meeting_id" => meeting_id,
      "relevant_until" => EmailActions.relevant_until(Keyword.fetch!(opts, :relevant_until))
    }

    args = maybe_put_previous_start(args, Keyword.get(opts, :previous_start_time))
    Jobs.delete_superseded_jobs(EmailWorker, args)

    args
    |> EmailWorker.new(
      queue: :emails,
      priority: 0,
      unique: [
        period: 300,
        fields: [:args, :queue],
        keys: [:action, :meeting_id],
        states: [:suspended, :available, :scheduled, :retryable]
      ]
    )
    |> Helpers.insert(meeting_id: meeting_id)
    |> Helpers.ok()
  end

  @doc """
  Schedules the email that asks an attendee to verify their address.

  `send` numbers the send: 1 for the email sent with the booking, and a higher
  number for each resend. It is part of the job's args and of its uniqueness,
  so enqueuing the same send twice within five minutes inserts one job, while
  a resend (a different number) is never swallowed by an earlier job. The
  handler claims its delivery per send as well.

  Inserts through Oban's repo, so called inside a `Repo.transaction` the job
  commits with the booking.
  """
  @spec schedule_verification_email(term(), pos_integer()) :: :ok | {:error, term()}
  def schedule_verification_email(meeting_id, send \\ 1) when is_integer(send) and send > 0 do
    %{"action" => "send_booking_email_verification", "meeting_id" => meeting_id, "send" => send}
    |> EmailWorker.new(
      queue: :emails,
      priority: 0,
      unique: [
        period: 300,
        fields: [:args, :queue],
        keys: [:action, :meeting_id, :send]
      ]
    )
    |> Helpers.insert(meeting_id: meeting_id)
    |> Helpers.ok()
  end

  # A reschedule back into the approval gate knows the time the booking was
  # moved from; nothing persists it, so the job carries it to the emails.
  defp maybe_put_previous_start(args, %DateTime{} = previous),
    do: Map.put(args, "previous_start_time", DateTime.to_iso8601(previous))

  defp maybe_put_previous_start(args, _previous), do: args

  @doc """
  Schedules the single reminder sent to a host who has not yet answered.

  Fires at `send_at`, halfway through the approval window, and is dropped
  unsent past `relevant_until`, the approval deadline. Uniqueness is keyed
  on the meeting alone with a ten-year period and restricted to `:incomplete`
  states, so a reschedule that re-enters the gate cannot stack a second nudge
  on a still-pending one (the deletion in `cancel_approval_emails/1` is what
  allows a genuinely new one to be inserted at all), while a nudge that has
  already fired for an earlier request does not block a fresh one for a
  re-entered one — Oban's default unique scope matches completed jobs too,
  and this meeting may cycle through the approval gate more than once.
  """
  @spec schedule_approval_nudge(term(), DateTime.t(), DateTime.t() | nil) ::
          :ok | {:error, term()}
  def schedule_approval_nudge(meeting_id, %DateTime{} = send_at, relevant_until) do
    delete_existing_approval_jobs(meeting_id)

    %{
      "action" => "send_booking_approval_nudge",
      "meeting_id" => meeting_id,
      "relevant_until" => EmailActions.relevant_until(relevant_until)
    }
    |> EmailWorker.new(
      queue: :emails,
      priority: 1,
      scheduled_at: send_at,
      unique: [
        period: 315_360_000,
        fields: [:args, :queue],
        keys: [:action, :meeting_id],
        states: :incomplete
      ]
    )
    |> Helpers.insert(meeting_id: meeting_id)
    |> Helpers.ok()
  end

  @doc """
  Schedules the invitee's email for a request that will not happen.

  Sent immediately, not scheduled: an invitee whose time was held is owed the
  news the moment it stops being held. Uniqueness is keyed on the action and
  the meeting, so the expiry job and the sweep both firing produces one email.
  `relevant_until` is `nil` for a decline, which is owed however late.
  """
  @spec schedule_request_outcome(term(), :declined | :expired, DateTime.t() | nil) ::
          :ok | {:error, term()}
  def schedule_request_outcome(meeting_id, variant, relevant_until)
      when variant in [:declined, :expired] do
    %{
      "action" => "send_booking_request_outcome",
      "meeting_id" => meeting_id,
      "variant" => Atom.to_string(variant),
      "relevant_until" => EmailActions.relevant_until(relevant_until)
    }
    |> EmailWorker.new(
      queue: :emails,
      priority: 0,
      unique: [period: 300, fields: [:args, :queue], keys: [:action, :meeting_id]]
    )
    |> Helpers.insert(meeting_id: meeting_id)
    |> Helpers.ok()
  end

  @doc """
  Schedules the host's email for a confirmed booking cancelled because the
  invitee's request to move it lapsed. Sent immediately, and unique per
  meeting like the invitee's outcome email.
  """
  @spec schedule_reschedule_request_expired(term()) :: :ok | {:error, term()}
  def schedule_reschedule_request_expired(meeting_id) do
    %{"action" => "send_reschedule_request_expired", "meeting_id" => meeting_id}
    |> EmailWorker.new(
      queue: :emails,
      priority: 0,
      unique: [period: 300, fields: [:args, :queue], keys: [:action, :meeting_id]]
    )
    |> Helpers.insert(meeting_id: meeting_id)
    |> Helpers.ok()
  end

  @doc """
  Schedules the two emails for a host's reschedule request that lapsed
  unanswered: the host's, saying the meeting expired, and the attendees',
  saying the request has lapsed (every live participant on a group meeting).
  Sent immediately, each unique per meeting, so a repeated expiry queues
  nothing new, and dropped unsent past `relevant_until`
  (`Tymeslot.Notifications.Relevance.reschedule_lapse/1`).
  """
  @spec schedule_reschedule_request_lapsed(term(), DateTime.t() | nil) :: :ok | {:error, term()}
  def schedule_reschedule_request_lapsed(meeting_id, relevant_until) do
    with :ok <-
           schedule_lapse_email("send_reschedule_request_unanswered", meeting_id, relevant_until) do
      schedule_lapse_email("send_reschedule_request_lapsed", meeting_id, relevant_until)
    end
  end

  defp schedule_lapse_email(action, meeting_id, relevant_until) do
    %{
      "action" => action,
      "meeting_id" => meeting_id,
      "relevant_until" => EmailActions.relevant_until(relevant_until)
    }
    |> EmailWorker.new(
      queue: :emails,
      priority: 0,
      unique: [period: 300, fields: [:args, :queue], keys: [:action, :meeting_id]]
    )
    |> Helpers.insert(meeting_id: meeting_id)
    |> Helpers.ok()
  end

  @doc """
  Schedules the cancellation to the guests of a held request that was
  declined or expired after a reschedule sent it back into the gate, once
  they had been invited. Sent immediately, and unique per meeting, as
  `schedule_reschedule_request_expired/1` is.
  """
  @spec schedule_released_guest_cancellations(term()) :: :ok | {:error, term()}
  def schedule_released_guest_cancellations(meeting_id) do
    %{"action" => "send_released_guest_cancellations", "meeting_id" => meeting_id}
    |> EmailWorker.new(
      queue: :emails,
      priority: 0,
      unique: [period: 300, fields: [:args, :queue], keys: [:action, :meeting_id]]
    )
    |> Helpers.insert(meeting_id: meeting_id)
    |> Helpers.ok()
  end

  @doc """
  Deletes any pending nudge for a meeting.

  Called on every exit from the approval gate. A nudge that fires after the
  host has already answered would ask them to decide something they decided.
  """
  @spec cancel_approval_emails(term()) :: :ok
  def cancel_approval_emails(meeting_id) do
    delete_existing_approval_jobs(meeting_id)
    :ok
  end

  defp delete_existing_approval_jobs(meeting_id) do
    Jobs.delete_jobs_by_action(
      EmailWorker,
      "send_booking_approval_nudge",
      meeting_id
    )
  end

  @doc """
  Schedules the notices for a booking that moved, to its organiser, attendee
  and guests, sent at once with high priority
  (`Tymeslot.Notifications.Email.RescheduleEmails`).

  `original` is the time the booking moved from, `%{start_time:, end_time:,
  attendee_video_url:}`, which the meeting row no longer holds, so the job
  carries it; `nil` for a booking whose new time the host approved after a
  reschedule, whose previous time is no longer known. Not unique: every move
  is its own notice.

  The job also carries the time `meeting` moved to and the status the move
  left it in, so a notice overtaken by a later move, a cancellation or a
  pending reschedule request is dropped rather than sent with times it never
  announced. `moved_by: :host` in `opts` marks a move the host made in their
  own calendar, which the organiser's copy then says.
  """
  @spec schedule_reschedule_emails(
          %{id: term(), start_time: DateTime.t(), status: MeetingState.status()},
          map() | nil,
          keyword()
        ) :: :ok | {:error, term()}
  def schedule_reschedule_emails(meeting, original, opts \\ []) do
    %{
      "action" => "send_reschedule_emails",
      "meeting_id" => meeting.id,
      "rescheduled_to" => DateTime.to_iso8601(meeting.start_time),
      "status" => Atom.to_string(meeting.status)
    }
    |> maybe_put_original(original)
    |> maybe_put_moved_by(Keyword.get(opts, :moved_by))
    |> EmailWorker.new(queue: :emails, priority: 0)
    |> Helpers.insert(meeting_id: meeting.id)
    |> Helpers.ok()
  end

  defp maybe_put_moved_by(args, :host), do: Map.put(args, "moved_by", "host")
  defp maybe_put_moved_by(args, nil), do: args

  defp maybe_put_original(args, nil), do: args

  defp maybe_put_original(args, original) do
    Map.put(args, "original", %{
      "start_time" => DateTime.to_iso8601(original.start_time),
      "end_time" => DateTime.to_iso8601(original.end_time),
      "attendee_video_url" => Map.get(original, :attendee_video_url)
    })
  end

  @doc """
  Schedules cancellation emails to be sent immediately with high priority.

  `seat_refund:` (`Tymeslot.Meetings.Cancellation.seat_refund/0`) is
  carried to the job as `"seat_refund"`, with string keys, for the
  organiser's email of a group session the host cancelled:
  `%{"choice" => "full", "count" => 2, "totals" => [%{"currency" => "eur",
  "amount_cents" => 8000}], "outside_window" => %{"count" => 1, "totals" =>
  [...]}}`, the last for the seats past the refund window.
  """
  @spec schedule_cancellation_emails(term(), keyword()) :: :ok | {:error, term()}
  def schedule_cancellation_emails(meeting_id, opts \\ []) do
    %{"action" => "send_cancellation_emails", "meeting_id" => meeting_id}
    |> Map.merge(seat_refund_arg(Keyword.get(opts, :seat_refund)))
    |> EmailWorker.new(
      queue: :emails,
      # Highest priority for cancellations
      priority: 0,
      unique: [
        # 5 minutes uniqueness window
        period: 300,
        fields: [:args, :queue],
        keys: [:action, :meeting_id]
      ]
    )
    |> Helpers.insert(meeting_id: meeting_id)
    |> Helpers.ok()
  end

  defp seat_refund_arg(%{choice: choice, outside_window: outside_window} = seat_refund)
       when choice in [:full, :none] do
    %{
      "seat_refund" =>
        seat_count_arg(seat_refund)
        |> Map.put("choice", Atom.to_string(choice))
        |> Map.put("outside_window", seat_count_arg(outside_window))
    }
  end

  defp seat_refund_arg(nil), do: %{}

  defp seat_count_arg(%{count: count, totals: totals}) do
    %{
      "count" => count,
      "totals" =>
        Enum.map(totals, &%{"currency" => &1.currency, "amount_cents" => &1.amount_cents})
    }
  end

  @doc """
  Schedules reminder emails to be sent at a specific time with medium priority.
  If no `scheduled_at` is provided, defaults to the reminder interval before the meeting.
  """
  @spec schedule_reminder_emails(term(), term(), term(), DateTime.t() | nil) ::
          :ok | {:error, term()}
  def schedule_reminder_emails(meeting_id, reminder_value, reminder_unit, scheduled_at \\ nil) do
    case Reminders.normalize_reminder(%{value: reminder_value, unit: reminder_unit}) do
      {:ok, %{value: value, unit: unit}} ->
        scheduled_at =
          scheduled_at || calculate_reminder_time(meeting_id, value, unit)

        # The meeting start this reminder is pinned to, outside the unique
        # keys: a job left over from before a move (one executing as the move
        # lands) sees the meeting no longer starts then and discards itself.
        pinned_start =
          DateTime.add(
            scheduled_at,
            Reminders.reminder_interval_seconds(value, unit),
            :second
          )

        %{
          "action" => "send_reminder_emails",
          "meeting_id" => meeting_id,
          "reminder_value" => value,
          "reminder_unit" => unit,
          "start_time" => DateTime.to_iso8601(pinned_start),
          # A reminder delivered after the meeting starts reminds nobody.
          "relevant_until" => EmailActions.relevant_until(pinned_start)
        }
        |> EmailWorker.new(
          queue: :emails,
          # Medium priority for reminders
          priority: 2,
          scheduled_at: scheduled_at,
          unique: [
            # Prevent duplicate reminders across long lead times (10 years in seconds).
            # Only jobs still waiting to run count: a reminder that already
            # fired, or one executing right now for the old time (which a
            # reschedule's clearing of pending reminders cannot delete), must
            # never stop the reminder for the new time being pinned.
            period: 315_360_000,
            fields: [:args, :queue],
            keys: [:action, :meeting_id, :reminder_value, :reminder_unit],
            states: [:suspended, :available, :scheduled, :retryable]
          ]
        )
        |> Helpers.insert(meeting_id: meeting_id, scheduled_at: scheduled_at)
        |> Helpers.ok()

      _error ->
        {:error, "invalid_reminder"}
    end
  end

  @doc """
  Deletes all pending reminder email jobs for a meeting.

  Used when the meeting's scheduled time stops being valid — cancellation or
  an organizer reschedule request — so no reminder fires for a void time slot.
  """
  @spec cancel_reminder_emails(term()) :: :ok
  def cancel_reminder_emails(meeting_id) do
    {deleted, _result} =
      Jobs.delete_reminder_jobs_for_meeting(meeting_id, EmailWorker, %{})

    Logger.info("Cancelled pending reminder email jobs",
      meeting_id: meeting_id,
      deleted_count: deleted
    )

    :ok
  end

  @doc """
  Schedules the reschedule request email for a meeting.

  `requested_at` is the meeting's `reschedule_requested_at`, and names the
  request: unique on it, so a re-run for the same request queues nothing,
  while a later request for the same meeting is a new email. The job carries
  it as ISO 8601. Dropped unsent once the request can no longer be answered,
  judged when it runs
  (`Tymeslot.Notifications.Email.RescheduleRequestEmails.check_answerable/1`).
  """
  @spec schedule_reschedule_request(term(), DateTime.t()) :: :ok | {:error, term()}
  def schedule_reschedule_request(meeting_id, %DateTime{} = requested_at) do
    job_params = %{
      "action" => "send_reschedule_request",
      "meeting_id" => meeting_id,
      "requested_at" => DateTime.to_iso8601(requested_at)
    }

    job_params
    |> EmailWorker.new(
      queue: :emails,
      priority: 1,
      # The window matches the per-seat jobs this one dispatches to, for the
      # same reason (see `Tymeslot.Emails.EmailScheduler.SeatScheduler.schedule_seat_email/5`).
      unique: [
        period: 3600,
        fields: [:args, :queue],
        keys: [:action, :meeting_id, :requested_at]
      ]
    )
    |> Helpers.insert(meeting_id: meeting_id)
    |> Helpers.ok()
  end

  # Private helpers

  defp calculate_reminder_time(meeting_id, reminder_value, reminder_unit) do
    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, meeting} ->
        seconds = Reminders.reminder_interval_seconds(reminder_value, reminder_unit)
        DateTime.add(meeting.start_time, -seconds, :second)

      {:error, :not_found} ->
        # Fallback to current time if meeting not found
        DateTime.utc_now()
    end
  end
end
