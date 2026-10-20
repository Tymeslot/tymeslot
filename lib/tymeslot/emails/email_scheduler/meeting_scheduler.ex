defmodule Tymeslot.Emails.EmailScheduler.MeetingScheduler do
  @moduledoc "Schedules meeting-related emails via Oban."

  alias Tymeslot.Emails.EmailActions
  alias Tymeslot.Emails.EmailScheduler.Helpers
  alias Tymeslot.Jobs
  alias Tymeslot.Meetings.MeetingQueries
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

  Restricted to `:incomplete` unique states minus `:executing`, so a fast
  reschedule that calls this again for the same meeting is neither
  swallowed by the first pair's completed job nor by one still executing.
  """
  @spec schedule_request_emails(term(), keyword()) :: :ok | {:error, term()}
  def schedule_request_emails(meeting_id, opts \\ []) do
    args = %{"action" => "send_booking_request_emails", "meeting_id" => meeting_id}

    args = maybe_put_previous_start(args, Keyword.get(opts, :previous_start_time))

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

  # A reschedule back into the approval gate knows the time the booking was
  # moved from; nothing persists it, so the job carries it to the emails.
  defp maybe_put_previous_start(args, %DateTime{} = previous),
    do: Map.put(args, "previous_start_time", DateTime.to_iso8601(previous))

  defp maybe_put_previous_start(args, _previous), do: args

  @doc """
  Schedules the single reminder sent to a host who has not yet answered.

  Fires at `send_at`, halfway through the approval window. Uniqueness is keyed
  on the meeting alone with a ten-year period and restricted to `:incomplete`
  states, so a reschedule that re-enters the gate cannot stack a second nudge
  on a still-pending one (the deletion in `cancel_approval_emails/1` is what
  allows a genuinely new one to be inserted at all), while a nudge that has
  already fired for an earlier request does not block a fresh one for a
  re-entered one — Oban's default unique scope matches completed jobs too,
  and this meeting may cycle through the approval gate more than once.
  """
  @spec schedule_approval_nudge(term(), DateTime.t()) :: :ok | {:error, term()}
  def schedule_approval_nudge(meeting_id, %DateTime{} = send_at) do
    delete_existing_approval_jobs(meeting_id)

    %{"action" => "send_booking_approval_nudge", "meeting_id" => meeting_id}
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
  """
  @spec schedule_request_outcome(term(), :declined | :expired) :: :ok | {:error, term()}
  def schedule_request_outcome(meeting_id, variant) when variant in [:declined, :expired] do
    %{
      "action" => "send_booking_request_outcome",
      "meeting_id" => meeting_id,
      "variant" => Atom.to_string(variant)
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

  # The per-seat action names live in `Tymeslot.Emails.EmailActions` with
  # every other action; call sites name them by atom.
  defdelegate seat_action(seat_action), to: EmailActions

  @doc """
  Schedules a single-seat email job.

  One job per `(action, meeting_id, participant_id)` plus whatever names
  one logical email among several of the same action for the same seat
  (`extra_keys`, each a key of `extra_args`): the shared shape behind every
  per-seat email action (confirmation, cancellation, reschedule, and the
  whole-meeting cancellation/reminder/reschedule-request fan-outs), so each
  recipient retries independently of the others and a different action for
  the same participant can never collide with this one. `extra_args` carries
  whatever the action needs beyond the two ids (e.g. `slot_freed`, the
  moved-from seat, or the reminder interval).

  The uniqueness covers completed jobs too, which is the point: a dispatcher
  re-run must not send a seat its email a second time. So anything that can
  legitimately send the same action to the same seat twice must say which
  email it is in `extra_keys`. A meeting with reminders at one hour and at 15
  minutes sends two different reminders, keyed by their offset; a host's
  second reschedule request is a second email, keyed by when it was made.

  The uniqueness window is wider than the usual 5 minutes deliberately: a
  seat job that hits an open mail circuit breaker snoozes for the breaker's
  recovery window plus jitter (up to ~330 seconds — see
  `Tymeslot.Workers.TransactionalEmailDelivery`), and a meeting-level
  dispatcher retried after its own circuit-open snooze re-runs this function
  for every participant again. A 5-minute window would have already elapsed
  by the time either of those wake up, so the just-inserted (or just
  completed) per-seat job would no longer read as a duplicate and this would
  insert a second one — re-sending to a participant who already got their
  email instead of the harmless no-op re-dispatch is meant to be.
  """
  @spec schedule_seat_email(String.t(), term(), term(), map(), [atom()]) ::
          :ok | {:error, term()}
  def schedule_seat_email(action, meeting_id, participant_id, extra_args \\ %{}, extra_keys \\ []) do
    extra_args
    |> Map.merge(%{
      "action" => action,
      "meeting_id" => meeting_id,
      "participant_id" => participant_id
    })
    |> EmailWorker.new(
      queue: :emails,
      priority: 0,
      unique: [
        # 1 hour — comfortably past the ~330s worst-case circuit-open
        # snooze on either the seat job itself or the meeting-level
        # dispatcher that re-runs this. See the moduledoc above.
        period: 3600,
        fields: [:args, :queue],
        keys: [:action, :meeting_id, :participant_id | extra_keys]
      ]
    )
    |> Helpers.insert(meeting_id: meeting_id, participant_id: participant_id)
    |> Helpers.ok()
  end

  @doc """
  Schedules the confirmation emails for a single group-booking seat.
  """
  @spec schedule_seat_confirmation_emails(term(), term()) :: :ok | {:error, term()}
  def schedule_seat_confirmation_emails(meeting_id, participant_id),
    do: schedule_seat_email(seat_action(:seat_confirmation), meeting_id, participant_id)

  @doc """
  Schedules the cancellation emails for a single group-booking seat.
  `slot_freed?` says the seat was the last one and its leaving cancelled the
  meeting.
  """
  @spec schedule_seat_cancellation_emails(term(), term(), boolean()) ::
          :ok | {:error, term()}
  def schedule_seat_cancellation_emails(meeting_id, participant_id, slot_freed?) do
    schedule_seat_email(seat_action(:seat_cancellation), meeting_id, participant_id, %{
      "slot_freed" => slot_freed?
    })
  end

  @doc """
  Schedules the reschedule emails for a single group-booking seat.

  `participant_id` is the seat at its new time; `old_participant_id` is the
  cancelled row it moved from, whose own calendar entry (UID, revision and
  time) the job cancels for the participant and their guests. A seat move
  never rewrites that row, so it is read when the job runs.
  `old_slot_freed?` says the move emptied, and so cancelled, the old meeting.
  """
  @spec schedule_seat_reschedule_emails(term(), term(), term(), boolean()) ::
          :ok | {:error, term()}
  def schedule_seat_reschedule_emails(
        meeting_id,
        participant_id,
        old_participant_id,
        old_slot_freed?
      ) do
    schedule_seat_email(seat_action(:seat_reschedule), meeting_id, participant_id, %{
      "old_participant_id" => old_participant_id,
      "old_slot_freed" => old_slot_freed?
    })
  end

  @doc """
  Schedules one live participant's copy of a whole-meeting cancellation.

  Dispatched (one call per live participant) from the meeting-level
  cancellation job instead of sending inline, so a failure on one participant
  cannot discard the notification to the rest.
  """
  @spec schedule_seat_meeting_cancellation_email(term(), term()) :: :ok | {:error, term()}
  def schedule_seat_meeting_cancellation_email(meeting_id, participant_id),
    do: schedule_seat_email(seat_action(:seat_meeting_cancellation), meeting_id, participant_id)

  @doc """
  Schedules one live participant's reminder.

  Dispatched (one call per live participant) from the meeting-level reminder
  job instead of sending inline, so a failure on one participant cannot
  discard the reminder to the rest.
  """
  @spec schedule_seat_reminder_email(term(), term(), term(), term()) ::
          :ok | {:error, term()}
  def schedule_seat_reminder_email(meeting_id, participant_id, reminder_value, reminder_unit) do
    schedule_seat_email(
      seat_action(:seat_reminder),
      meeting_id,
      participant_id,
      %{"reminder_value" => reminder_value, "reminder_unit" => reminder_unit},
      [:reminder_value, :reminder_unit]
    )
  end

  @doc """
  Schedules one live participant's reschedule request.

  Dispatched (one call per live participant) from the meeting-level
  reschedule-request job instead of sending inline, so a failure on one
  participant cannot discard the request to the rest.

  `requested_at` (the meeting's `reschedule_requested_at`, as ISO 8601, or
  `nil`) names the request: a re-run of the same dispatch is a duplicate, a
  later request is a new email.
  """
  @spec schedule_seat_reschedule_request(term(), term(), String.t() | nil) ::
          :ok | {:error, term()}
  def schedule_seat_reschedule_request(meeting_id, participant_id, requested_at) do
    schedule_seat_email(
      seat_action(:seat_reschedule_request),
      meeting_id,
      participant_id,
      %{"requested_at" => requested_at},
      [:requested_at]
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
          %{id: term(), start_time: DateTime.t(), status: String.t()},
          map() | nil,
          keyword()
        ) :: :ok | {:error, term()}
  def schedule_reschedule_emails(meeting, original, opts \\ []) do
    %{
      "action" => "send_reschedule_emails",
      "meeting_id" => meeting.id,
      "rescheduled_to" => DateTime.to_iso8601(meeting.start_time),
      "status" => meeting.status
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
  """
  @spec schedule_cancellation_emails(term()) :: :ok | {:error, term()}
  def schedule_cancellation_emails(meeting_id) do
    %{"action" => "send_cancellation_emails", "meeting_id" => meeting_id}
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
          "start_time" => DateTime.to_iso8601(pinned_start)
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
  it as ISO 8601.
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
      # same reason (see `schedule_seat_email/5`).
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
