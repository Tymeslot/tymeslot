defmodule Tymeslot.Meetings.Approval do
  @moduledoc """
  The manual-approval gate: bookings a host holds before agreeing to them.

  A meeting type with `requires_approval` set does not confirm its bookings on
  submission. The meeting is inserted as `:awaiting_approval`, which occupies
  its slot exactly as a confirmed booking does, and waits for the host to
  answer. Four things can end that wait, and this module owns all four.

  ## Why the transitions live in one module

  Every exit from the gate races every other one. The host can approve in the
  dashboard while the expiry job is firing; they can click Approve twice; a
  colleague can decline from a forwarded email after the host already accepted;
  the invitee can withdraw the request mid-decision. A read-then-write would
  let the second writer overwrite the first, and the failure is not cosmetic —
  it produces a confirmed meeting the host declined, or a released slot the
  host accepted.

  So the status change is a single guarded `UPDATE ... WHERE status =
  'awaiting_approval'` (`MeetingTransitionQueries.transition_from_awaiting_approval/2`).
  Every exit from the gate goes through it — including the invitee's own
  withdrawal and an external actor (the host deleting the tentative hold from
  their own calendar), both reached through `Bookings.Cancel`, which
  delegates back into `withdraw/2` rather than writing the status itself — so
  exactly one caller wins; the rest get `{:error, :not_awaiting_approval}`,
  which surfaces as "this request was already answered" rather than as a
  failure.

  ## What each exit means

    * `approve/1` — the host agrees. The meeting becomes `:confirmed` and
      joins the ordinary booking pipeline through `Bookings.Activation`: the
      same video room, the same confirmation emails, the same reminders and
      webhooks an ungated booking would have produced. The invitee's second
      email is deliberately the standard confirmation, so it looks like every
      other Tymeslot booking. Answering after the request's own
      `approval_deadline_at` does not confirm it — see "The deadline" below.

    * `decline/2` — the host says no. The meeting becomes `:cancelled`, which
      is not a compromise but the accurate status: the slot is released, the
      tentative calendar event removed, and the attendee told. A booking that
      was paid for but never approved gave the attendee nothing, so `ApprovalRelease`
      refunds the full remaining balance itself rather than deferring to the
      cancellation pipeline, which exists for a meeting the attendee actually
      got to have and offers the host no such choice here — unless the request
      already *was* such a meeting before it re-entered the gate (see
      `Tymeslot.Meetings.ApprovalRefunds.refund_unapproved_request/1`). What distinguishes a decline from every
      other cancelled meeting is `approval_declined_at`, which only this path
      stamps; ask `declined?/1` rather than reading it directly.

    * `expire/1` — nobody answered in time. Identical to a decline apart from
      the status (`:expired`) and the wording the invitee receives: the host
      did not refuse, the window simply lapsed. Silence never means yes.

    * `withdraw/2` — the invitee changes their mind, or the host deletes the
      tentative hold from their own calendar and `Bookings.Cancel` treats
      that as a withdrawal on their behalf. Mechanically identical to
      `decline/2` and `expire/1` — same guard, same refund rule, same video
      and calendar release — but distinct in meaning: nobody refused the
      request and nobody ran out the clock, so neither
      `approval_resolved_at` nor `approval_declined_at` is set, and the
      invitee gets `Bookings.Cancel`'s ordinary cancellation email rather
      than a decline or expiry notice.

  ## A series is one request

  A session of a booking series held for approval is not answered on its
  own: while the series request is open
  (`Tymeslot.BookingSeries.Approval.series_request?/1`), `approve/1`,
  `decline/2`, `expire/1` and `withdraw/2` on any of its sessions act on the
  whole series, and return the session they were given, as it now is. A
  confirmed session the booker moved back into the gate is a request of its
  own, answered here like any other. So the dashboard's request card, the host's email links and
  the expiry jobs need not know about series. That includes an external
  calendar delete of one session's tentative event (`Bookings.Cancel`,
  `withdrawn_by: :calendar`): it withdraws the whole series, since a series
  missing one session is not the series that was asked for.

  ## The deadline

  `deadline_for/2` is capped at the meeting's own start time. A request for a
  meeting in six hours cannot have a twenty-four hour window; it lapses when
  the meeting would have begun, because approving a booking whose slot has
  already passed helps nobody. `approve/1` enforces that deadline itself
  rather than trusting that the expiry sweep gets there first: a host
  answering after the window the invitee was promised gets the same outcome
  the sweep would have produced (the request is released as `:expired`),
  not a late confirmation.
  """

  require Logger

  alias Tymeslot.Availability
  alias Tymeslot.Bookings.Activation
  alias Tymeslot.Bookings.CalendarJobs
  alias Tymeslot.BookingSeries.Approval, as: SeriesApproval
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings.ApprovalRelease
  alias Tymeslot.Meetings.CommittedStep
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.MeetingTransitionQueries
  alias Tymeslot.MeetingTypes.MeetingTypeSchema, as: MeetingType
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Notifications.Orchestrator
  alias Tymeslot.Repo
  alias Tymeslot.Validation.Constraints

  @typedoc "Why a transition out of the approval gate did not happen."
  @type error :: :not_awaiting_approval | :meeting_started | :slot_taken | :not_scheduled

  @doc """
  Whether bookings on this meeting type are held for the host to approve.

  Accepts `nil` so callers that may not have resolved a meeting type — ad-hoc
  host bookings, demo profiles — need no separate branch. No meeting type
  means no gate.
  """
  @spec required?(MeetingType.t() | map() | nil) :: boolean()
  def required?(nil), do: false
  def required?(%{requires_approval: true}), do: true
  def required?(_meeting_type), do: false

  @doc """
  Whether this meeting was refused by its host.

  The one question three call sites need answered — the `meeting.cancelled`
  webhook body, the invitee's request page and the paid return page — and one
  they must not answer for themselves. A decline is deliberately stored as
  `status: :cancelled` so the ordinary cancellation pipeline applies to it,
  which leaves `status` unable to tell the two apart, and
  `approval_resolved_at` cannot either: `approve/1` stamps it too, so an
  approved booking that is later cancelled normally carries it for the rest of
  its life. Only `approval_declined_at` is written by `decline/2` alone.
  """
  @spec declined?(Meeting.t() | map() | nil) :: boolean()
  def declined?(%{approval_declined_at: %DateTime{}}), do: true
  def declined?(_meeting), do: false

  @doc """
  How long the host has to answer, in hours.

  A meeting type storing no window uses the application default rather than
  freezing today's value into every row.
  """
  @spec window_hours(MeetingType.t() | map() | nil) :: pos_integer()
  def window_hours(%{approval_window_hours: hours}) when is_integer(hours) and hours > 0,
    do: hours

  def window_hours(_meeting_type), do: Constraints.default_approval_window_hours()

  @doc """
  When a request made now must be answered by.

  Never later than the meeting's own start time: a slot that has already begun
  cannot be given away, so a request against it stops being answerable then
  rather than at a deadline computed from the window alone.
  """
  @spec deadline_for(MeetingType.t() | map() | nil, DateTime.t(), DateTime.t()) :: DateTime.t()
  def deadline_for(meeting_type, %DateTime{} = requested_at, %DateTime{} = start_time) do
    window_end = DateTime.add(requested_at, window_hours(meeting_type) * 3600, :second)

    window_end
    |> earliest(start_time)
    |> DateTime.truncate(:second)
  end

  @doc """
  The status and approval clock a booking is created with.

  A type requiring approval, with a known start, holds the booking as
  `:awaiting_approval` and stamps the window the host is answering against;
  anything else confirms with all three keys nil. `requested_at` is passed in
  so a booking whose host is only asked later (after the attendee verifies
  their email) starts the clock then, not at submission.
  """
  @spec request_attributes(MeetingType.t() | map() | nil, DateTime.t(), DateTime.t() | nil) :: %{
          status: :confirmed | :awaiting_approval,
          approval_requested_at: DateTime.t() | nil,
          approval_deadline_at: DateTime.t() | nil
        }
  def request_attributes(meeting_type, %DateTime{} = requested_at, start_time) do
    if required?(meeting_type) and not is_nil(start_time) do
      requested_at = DateTime.truncate(requested_at, :second)

      %{
        status: :awaiting_approval,
        approval_requested_at: requested_at,
        approval_deadline_at: deadline_for(meeting_type, requested_at, start_time)
      }
    else
      %{status: :confirmed, approval_requested_at: nil, approval_deadline_at: nil}
    end
  end

  @doc """
  Recomputes a held request's deadline for a clock that starts later than the
  booking did, keeping the window the invitee was already promised.

  The paid path needs this: a booking on a gated type is stamped with its
  deadline at submission, but the host is only asked once Stripe confirms the
  money cleared, so the clock restarts at the webhook
  (`MeetingPayments.Webhooks.CheckoutSessionCompleted`). The window itself
  must survive that restart, and it is read back off the row rather than from
  the meeting type for the same reason the gate decision is: the type's
  `approval_window_hours` can be edited, or the type archived, while a Checkout
  session sits open for 24 hours, and neither may move a window an invitee has
  already been shown.

  The stored span carries the original start-time cap, which is harmless: a
  request capped once is capped again here, since the restart can only move the
  clock forward. A row with no stored span falls back to the default window.
  """
  @spec restart_deadline(Meeting.t() | map(), DateTime.t()) :: DateTime.t()
  def restart_deadline(meeting, %DateTime{} = restarted_at) do
    restarted_at
    |> DateTime.add(promised_window_seconds(meeting), :second)
    |> earliest(meeting.start_time)
    |> DateTime.truncate(:second)
  end

  defp promised_window_seconds(%{
         approval_requested_at: %DateTime{} = requested_at,
         approval_deadline_at: %DateTime{} = deadline_at
       }) do
    deadline_at |> DateTime.diff(requested_at, :second) |> max(0)
  end

  defp promised_window_seconds(_meeting),
    do: Constraints.default_approval_window_hours() * 3600

  @doc """
  Confirms a held booking and hands it to the ordinary booking pipeline.

  Refuses a meeting whose start time has passed: there is nothing left to
  confirm, and the invitee would receive a confirmation for a meeting that
  already did not happen. Declining is the honest action there, and the expiry
  sweep will take it.

  A request answered after its own `approval_deadline_at` is released as
  `:expired` (see "The deadline" in the moduledoc). The caller sees
  `{:error, :not_awaiting_approval}` either way, the same race-loss outcome
  shown whenever somebody else answered first, because by the time this
  returns the request is no longer awaiting approval.
  """
  @spec approve(Meeting.t()) :: {:ok, Meeting.t()} | {:error, error()}
  def approve(%Meeting{} = meeting) do
    case SeriesApproval.for_session(meeting, :approve) do
      :not_in_series -> approve_one(meeting)
      answered -> answered
    end
  end

  defp approve_one(meeting) do
    now = Clock.utc_now()

    cond do
      started?(meeting, now) -> {:error, :meeting_started}
      MeetingState.approval_deadline_passed?(meeting, now) -> approve_after_deadline(meeting)
      true -> do_approve(meeting, now)
    end
  end

  defp approve_after_deadline(meeting) do
    case expire(meeting) do
      {:ok, _released} -> {:error, :not_awaiting_approval}
      {:error, _reason} = error -> error
    end
  end

  defp do_approve(meeting, now) do
    case confirm(meeting, now) do
      {:ok, {confirmed, pending}} ->
        Logger.info("Booking request approved", meeting_id: confirmed.id)
        Availability.changed(confirmed.organizer_user_id)
        activate_confirmed(confirmed, pending)

        {:ok, confirmed}

      {:error, :not_awaiting_approval} = error ->
        Logger.info("Approval skipped: request no longer held",
          meeting_id: meeting.id,
          status: meeting.status
        )

        error

      # Somebody else's booking took the slot while this request sat held. The
      # partial unique index spans `confirmed` and `awaiting_approval` together,
      # so confirming this one would collide with the row that won. The request
      # stays held rather than being released: the host may still be able to
      # decline it deliberately, and the expiry sweep will free it otherwise.
      {:error, :slot_taken} = error ->
        Logger.info("Approval refused: the slot was taken by another booking",
          meeting_id: meeting.id,
          start_time: meeting.start_time
        )

        error

      # The confirmation emails or reminders could not be enqueued, so the
      # approval rolled back and the request is still held for the host to
      # approve again.
      {:error, reason} ->
        Logger.error("Approval rolled back: the confirmation could not be scheduled",
          meeting_id: meeting.id,
          reason: LogFormat.reason(reason)
        )

        {:error, :not_scheduled}
    end
  end

  # The confirmation and its emails and reminders commit together: a
  # confirmed booking whose announcement was claimed but whose emails were
  # never queued would be one nobody is ever told about.
  defp confirm(meeting, now) do
    Repo.transaction(fn ->
      with {:ok, confirmed} <-
             MeetingTransitionQueries.transition_from_awaiting_approval(meeting.id,
               status: :confirmed,
               approval_resolved_at: DateTime.truncate(now, :second)
             ),
           {:ok, pending} <- Activation.activate_in_transaction(confirmed, with_video_room: true) do
        {confirmed, pending}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Runs what a booking newly confirmed out of the approval gate needs once its
  confirmation has committed.

  `approve/1` calls this once its transaction has committed. It is public
  because approval is not the only way a held request becomes a confirmed
  booking: `Tymeslot.Bookings.Reschedule` confirms one outright when its
  meeting type stopped requiring approval while the request was still held,
  and that booking needs precisely the same treatment. There is no host answer
  to guard there — there is no gate left to answer — but the resulting meeting
  is indistinguishable from an approved one, and it has never been announced
  to anybody: without this it would have no confirmation email, no ICS, no
  video room, no reminders and no `meeting.created` webhook, while the request
  emails' nudge and expiry jobs stayed armed against a booking that is no
  longer held.

  Both callers have already run `Bookings.Activation.activate_in_transaction/2`
  in the transaction that confirmed the booking, so the video room job, the
  confirmation emails and the reminders committed with it or not at all;
  `pending` is the integration fan-out that returned. A booking confirmed
  before a reschedule sent it back into the gate is announced as rescheduled
  instead, to the invitee and to every integration
  (`Orchestrator.send_reapproval_notifications/1`,
  `Notifications.Events.meeting_created_deferred/2`).

  What is left runs here, in this order: stop the request notifications, flip
  the tentative calendar hold to a real event, fan out to webhooks, Telegram
  and Slack, and send any reapproval notice. Each step is best-effort and is
  separately retried or logged by its own module; the confirmation stands.
  """
  @spec activate_confirmed(Meeting.t(), Events.pending()) :: :ok
  def activate_confirmed(%Meeting{} = confirmed, pending) do
    CommittedStep.run(confirmed, "cancel request notifications", fn ->
      Orchestrator.cancel_request_notifications(confirmed)
    end)

    CommittedStep.run(confirmed, "confirm calendar event", fn ->
      confirm_calendar_event(confirmed)
    end)

    CommittedStep.run(confirmed, "announce to integrations", fn ->
      Activation.after_commit(pending)
    end)

    CommittedStep.run(confirmed, "send reschedule notifications", fn ->
      Orchestrator.send_reapproval_notifications(confirmed)
    end)

    :ok
  end

  @doc "Declines a held booking, releasing the slot. See `ApprovalRelease.decline/2`."
  @spec decline(Meeting.t(), String.t() | nil) :: {:ok, Meeting.t()} | {:error, error()}
  defdelegate decline(meeting, reason \\ nil), to: ApprovalRelease

  @doc "What a decline writes besides its status. See `ApprovalRelease.decline_changes/2`."
  @spec decline_changes(String.t() | nil, DateTime.t()) :: keyword()
  defdelegate decline_changes(reason, now), to: ApprovalRelease

  @doc "Releases a held booking whose deadline has passed. See `ApprovalRelease.expire/1`."
  @spec expire(Meeting.t()) :: {:ok, Meeting.t()} | {:error, error()}
  defdelegate expire(meeting), to: ApprovalRelease

  @doc "Withdraws a held request without the host refusing it. See `ApprovalRelease.withdraw/2`."
  @spec withdraw(Meeting.t(), keyword()) :: {:ok, Meeting.t()} | {:error, error()}
  defdelegate withdraw(meeting, extra_changes \\ []), to: ApprovalRelease

  @doc "Clears a committed release's jobs, calendar hold and video room. See `ApprovalRelease.clear_released_request/1`."
  @spec clear_released_request(Meeting.t()) :: :ok
  defdelegate clear_released_request(meeting), to: ApprovalRelease

  @doc "Whether releasing this request refunds its payment. See `ApprovalRelease.refunds_on_release?/1`."
  @spec refunds_on_release?(Meeting.t() | map()) :: boolean()
  defdelegate refunds_on_release?(meeting), to: ApprovalRelease

  # The booking already wrote a tentative event to hold the slot; approving it
  # has to turn that event into a real one. Without this the host's calendar
  # keeps showing a maybe for a meeting they agreed to, and every app reading
  # that calendar — including their colleagues' free/busy — reads it the same
  # way. The builder derives `status` from the meeting, so re-pushing the event
  # is the whole flip.
  #
  # The update job is always scheduled, the way `Bookings.Create` schedules its
  # "create" job and `Bookings.Reschedule` its own "update": whether there is
  # anything to flip is `CalendarEventSync`'s call. CalDAV addresses its event
  # by a Tymeslot-minted UID until its create job confirms it
  # (`CalendarEventSync.put_provider_mapping/2`), so no "has a provider event"
  # test made here can tell. The job falls back to uid-addressing, recreates
  # the event on a missing-event 404, and ends gracefully when there is no
  # calendar integration to update.
  #
  # Best-effort, like every other calendar write: the approval is committed and
  # a failed push is retried by the worker rather than undoing it.
  defp confirm_calendar_event(meeting) do
    schedule_calendar_confirm(meeting)
  end

  defp schedule_calendar_confirm(meeting) do
    case CalendarJobs.schedule_job(meeting, "update") do
      {:ok, _status} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule calendar update after approval",
          meeting_id: meeting.id,
          reason: LogFormat.reason(reason)
        )

        :ok
    end
  end

  defp started?(%Meeting{start_time: nil}, _now), do: false

  defp started?(%Meeting{start_time: start_time}, now),
    do: DateTime.compare(now, start_time) != :lt

  defp earliest(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)
end
