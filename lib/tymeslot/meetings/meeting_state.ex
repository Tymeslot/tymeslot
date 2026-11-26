defmodule Tymeslot.Meetings.MeetingState do
  @moduledoc """
  Single owner of predicates derived from a meeting's two independent state
  axes: `status` (the booking lifecycle — pending, awaiting_payment,
  awaiting_approval, awaiting_verification, confirmed, cancelled, completed)
  and
  `reschedule_requested_at` (whether the organizer is currently awaiting the
  attendee to pick a new time). The two axes are orthogonal: an organizer
  reschedule request leaves `status` untouched, so a `pending` or
  `awaiting_payment` meeting keeps that status while a request is pending.

  `status: :reschedule_requested` is a legacy value: no code writes it any
  more, but it remains a valid enum member so historical (or unmigrated) rows
  keep reading correctly here.
  """

  import Ecto.Query, warn: false

  alias Tymeslot.Clock
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting

  @pending :pending
  @awaiting_payment :awaiting_payment
  # Held pending the host's manual approval. Occupies its slot like a pending
  # booking does, but is not a booking anyone has agreed to yet.
  @awaiting_approval :awaiting_approval
  # Held until the attendee confirms their email address. Occupies its slot
  # so nobody else can take it, but is not active: the booking does not exist
  # for anyone yet, the organiser included.
  @awaiting_verification :awaiting_verification
  @confirmed :confirmed
  @cancelled :cancelled
  @completed :completed
  @expired :expired
  @reschedule_requested :reschedule_requested

  @active_statuses [@confirmed, @pending, @awaiting_approval, @reschedule_requested]

  # Statuses that occupy a calendar slot for conflict-detection purposes.
  # Combined with `exclude_voided_slots/1`, this is the query-side mirror of
  # `slot_void?/1`: a meeting only actually blocks a time window while it
  # holds one of these statuses AND has no pending reschedule request.
  #
  # An unverified booking holds its slot (so the attendee's time cannot be
  # taken while they check their inbox) but is not in `@active_statuses`,
  # because nothing may act on it until the attendee has verified.
  @occupying_statuses [
    @confirmed,
    @pending,
    @awaiting_payment,
    @awaiting_approval,
    @awaiting_verification
  ]

  # Statuses a booking is released in without taking place: cancelled, or a
  # request that expired unanswered. Releasing one deletes its video room.
  @released_statuses [@cancelled, @expired]

  # Statuses a meeting never leaves: it is over, one way or another, so
  # nothing may cancel, move or confirm it again.
  @terminal_statuses [@cancelled, @completed, @expired]

  # How long an attendee has to pick a new time after the host asks for one;
  # see `reschedule_request_deadline/1`.
  @reschedule_answer_days Application.compile_env(:tymeslot, :reschedule_answer_days, 7)

  @typedoc "Where a meeting stands in the booking lifecycle."
  @type status ::
          :pending
          | :awaiting_payment
          | :awaiting_approval
          | :awaiting_verification
          | :confirmed
          | :cancelled
          | :completed
          | :expired
          | :reschedule_requested

  @doc """
  Every status a meeting can hold: the values `MeetingSchema` declares for its
  `status` enum, which the groupings below are drawn from.
  """
  @spec statuses() :: [status()]
  def statuses, do: Ecto.Enum.values(Meeting, :status)

  @doc "The statuses `active?/1` accepts."
  @spec active() :: [status()]
  def active, do: @active_statuses

  @doc """
  The statuses that occupy a calendar slot for conflict detection; see
  `where_slot_live/1`, which also excludes voided slots.
  """
  @spec occupying() :: [status()]
  def occupying, do: @occupying_statuses

  @doc "The statuses `released_status?/1` accepts."
  @spec released() :: [status()]
  def released, do: @released_statuses

  @doc "The statuses `terminal?/1` accepts."
  @spec terminal() :: [status()]
  def terminal, do: @terminal_statuses

  @doc """
  Whether the meeting still represents a live booking a user should be able
  to interact with (view, cancel, reschedule). Excludes cancelled,
  completed, awaiting_payment, and expired.

  `awaiting_approval` is included: the invitee has committed to the time and
  may withdraw or move their request while the host decides. Only the host's
  agreement is missing, and that is what `confirmed` records.

  Does not gate calendar export: a meeting can be active with a void slot
  (e.g. a pending reschedule request), which must not be exportable. Use
  `expects_calendar_event?/1` for that.
  """
  @spec active?(Meeting.t()) :: boolean()
  def active?(%{status: status}), do: status in @active_statuses

  @doc """
  Whether the meeting's scheduled time slot is void: the meeting is
  cancelled, or an organizer reschedule request is pending and no new time
  has been booked yet. A void slot must not have reminders scheduled against
  it, nor a calendar event referencing it.
  """
  @spec slot_void?(Meeting.t()) :: boolean()
  def slot_void?(%{status: @cancelled}), do: true
  def slot_void?(%{status: @reschedule_requested}), do: true
  def slot_void?(%{reschedule_requested_at: nil}), do: false
  def slot_void?(%{reschedule_requested_at: %DateTime{}}), do: true

  @doc """
  Whether a provider calendar event should still exist for this meeting.
  Answers a different question from `active?/1` and `slot_void?/1`: `active?`
  is "may a user interact with it", `slot_void?` is "does its time slot
  still hold", and this is "should we expect a provider event on the
  organizer's calendar right now". A meeting can be active yet have a void
  slot (an organizer reschedule request pending, or the legacy
  `:reschedule_requested` status) — in that case we deliberately deleted or
  never created the provider event, so its absence must never be treated as
  an external deletion.

  Callers reconciling calendar state against provider signals (e.g.
  deciding whether a missing event implies an external deletion) must use
  this predicate, not `active?/1`.
  """
  @spec expects_calendar_event?(Meeting.t()) :: boolean()
  def expects_calendar_event?(meeting), do: active?(meeting) and not slot_void?(meeting)

  @doc """
  Whether the organizer is currently awaiting the attendee to pick a new
  time for this meeting. A meeting that is over awaits nothing, even when a
  request it was ended under is still stamped on it.
  """
  @spec awaiting_new_time?(Meeting.t()) :: boolean()
  def awaiting_new_time?(%{status: @reschedule_requested}), do: true
  def awaiting_new_time?(%{status: status}) when status in @terminal_statuses, do: false
  def awaiting_new_time?(%{reschedule_requested_at: %DateTime{}}), do: true
  def awaiting_new_time?(_meeting), do: false

  @doc """
  How long an attendee has to answer a reschedule request, in days, counted
  from when it was sent. See `reschedule_request_deadline/1`.
  """
  @spec reschedule_answer_days() :: pos_integer()
  def reschedule_answer_days, do: @reschedule_answer_days

  @doc """
  When an unanswered reschedule request lapses: the later of the meeting's
  original start and `reschedule_answer_days/0` after the request was sent,
  so a request sent just before the meeting still gets the whole window.
  `nil` for a meeting with no request stamped on it (including rows holding
  the legacy `:reschedule_requested` status alone), which never lapses.
  """
  @spec reschedule_request_deadline(Meeting.t() | map()) :: DateTime.t() | nil
  def reschedule_request_deadline(
        %{reschedule_requested_at: %DateTime{} = requested_at} = meeting
      ) do
    window_end = DateTime.add(requested_at, @reschedule_answer_days * 86_400, :second)

    case meeting do
      %{start_time: %DateTime{} = start} -> latest(start, window_end)
      _no_start -> window_end
    end
  end

  def reschedule_request_deadline(_meeting), do: nil

  @doc """
  Whether a reschedule request on the meeting has lapsed unanswered at `now`:
  it was expired already, or it is still open and its deadline
  (`reschedule_request_deadline/1`) has been reached. The deadline itself
  counts as reached, as for `approval_deadline_passed?/2`.
  """
  @spec reschedule_request_lapsed?(Meeting.t() | map(), DateTime.t()) :: boolean()
  def reschedule_request_lapsed?(meeting, now \\ Clock.utc_now())

  def reschedule_request_lapsed?(%{status: @expired, reschedule_requested_at: %DateTime{}}, _now),
    do: true

  def reschedule_request_lapsed?(meeting, now) do
    case awaiting_new_time?(meeting) and reschedule_request_deadline(meeting) do
      %DateTime{} = deadline -> DateTime.compare(now, deadline) != :lt
      _open_or_none -> false
    end
  end

  @doc """
  Query-side counterpart of `reschedule_request_lapsed?/2` for requests still
  open: meetings awaiting a new time whose deadline has been reached at
  `now`, in a status an expiry may end. A booking still waiting on its
  payment is left to its checkout's own expiry.
  """
  @spec where_reschedule_request_lapsed(Ecto.Queryable.t(), DateTime.t()) :: Ecto.Query.t()
  def where_reschedule_request_lapsed(query, %DateTime{} = now) do
    window_start = DateTime.add(now, -@reschedule_answer_days * 86_400, :second)

    query
    |> where([m], not is_nil(m.reschedule_requested_at))
    |> where([m], m.reschedule_requested_at <= ^window_start and m.start_time <= ^now)
    |> where([m], m.status not in ^[@awaiting_payment | @terminal_statuses])
  end

  defp latest(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)

  @doc """
  When a request that lapsed at `deadline` ended, for an expiry running at
  `now`: the deadline itself, so an expiry that runs late (a delayed job, a
  sweep catching up) does not date the end to whenever it ran. Never after
  `now`, and `now` for a request with no deadline. Truncated to the second,
  as the meeting's timestamp columns hold it.
  """
  @spec lapsed_at(DateTime.t() | nil, DateTime.t()) :: DateTime.t()
  def lapsed_at(nil, %DateTime{} = now), do: DateTime.truncate(now, :second)

  def lapsed_at(%DateTime{} = deadline, %DateTime{} = now) do
    earliest = if DateTime.compare(deadline, now) == :gt, do: now, else: deadline
    DateTime.truncate(earliest, :second)
  end

  @doc """
  Query-side counterpart of `slot_void?/1`, restricted to the statuses that
  occupy a slot (`@occupying_statuses`): composes onto `query` a filter
  matching only meetings whose slot is actually live, i.e. blocking the
  window from a new booking. Used by conflict-detection queries so the
  status list and the void check can't drift from the struct predicates
  above.
  """
  @spec where_slot_live(Ecto.Queryable.t()) :: Ecto.Query.t()
  def where_slot_live(query) do
    query
    |> where([m], m.status in ^@occupying_statuses)
    |> exclude_voided_slots()
  end

  @doc """
  Composes onto `query` a filter keeping the meetings the calendar
  draws: those whose slot is live (`where_slot_live/1`) and the requests that
  expired unanswered (`where_expired_request/1`).
  """
  @spec where_drawn(Ecto.Queryable.t()) :: Ecto.Query.t()
  def where_drawn(query) do
    live = query |> where_slot_live() |> select([m], m.id)
    expired = query |> where_expired_request() |> select([m], m.id)

    where(query, [m], m.id in subquery(live) or m.id in subquery(expired))
  end

  @doc """
  Query-side counterpart of `expects_calendar_event?/1`: composes onto `query`
  a filter matching only meetings that should have a provider event on the
  organiser's calendar right now. A write that follows the calendar puts it
  in its `WHERE`, so a meeting cancelled or voided after the provider event
  was read is left as it is.
  """
  @spec where_expects_calendar_event(Ecto.Queryable.t()) :: Ecto.Query.t()
  def where_expects_calendar_event(query) do
    query
    |> where([m], m.status in ^(@active_statuses -- [@reschedule_requested]))
    |> exclude_voided_slots()
  end

  # Query-side counterpart of `awaiting_new_time?/1`: excludes meetings whose
  # slot is currently voided by a pending reschedule request.
  defp exclude_voided_slots(query) do
    where(query, [m], is_nil(m.reschedule_requested_at))
  end

  @doc """
  Whether the meeting is held pending the host's manual approval.

  Distinct from `awaiting_new_time?/1`: there the organizer is waiting on the
  attendee, here the attendee is waiting on the organizer.
  """
  @spec awaiting_approval?(Meeting.t()) :: boolean()
  def awaiting_approval?(%{status: @awaiting_approval}), do: true
  def awaiting_approval?(_meeting), do: false

  @doc """
  Whether a paid booking is still waiting for its payment to complete. Its
  side effects, reminders included, are held until the payment lands.
  """
  @spec awaiting_payment?(Meeting.t() | map()) :: boolean()
  def awaiting_payment?(%{status: @awaiting_payment}), do: true
  def awaiting_payment?(_meeting), do: false

  @doc """
  Whether a held request's answer deadline has passed at `now`.

  The deadline itself counts as passed: a request is answerable strictly
  before `approval_deadline_at` and no longer at it, matching the expiry
  sweep's `approval_deadline_at <= now`. A meeting without a deadline never
  lapses by this predicate.

  Deliberately not used by `Tymeslot.Meetings.Workers.ApprovalExpiryWorker`,
  which releases a request whose deadline is missing rather than keeping it.
  """
  @spec approval_deadline_passed?(Meeting.t() | map(), DateTime.t()) :: boolean()
  def approval_deadline_passed?(meeting, now \\ Clock.utc_now())

  def approval_deadline_passed?(%{approval_deadline_at: nil}, _now), do: false

  def approval_deadline_passed?(%{approval_deadline_at: %DateTime{} = deadline}, now),
    do: DateTime.compare(now, deadline) != :lt

  @doc """
  Status counterpart of `awaiting_approval?/1`.

  For callers that hold the status alone rather than a meeting — the themes'
  confirmation screens read it off their assigns — so they need not fabricate
  a meeting-shaped map to ask the question, and the status literal stays
  defined once in this module.
  """
  @spec awaiting_approval_status?(status() | nil) :: boolean()
  def awaiting_approval_status?(@awaiting_approval), do: true
  def awaiting_approval_status?(_status), do: false

  @doc """
  Whether a meeting with `status` was released without taking place, so its
  video room is to be deleted rather than kept in step with the booking.
  """
  @spec released_status?(status() | nil) :: boolean()
  def released_status?(status), do: status in @released_statuses

  @doc "Query-side counterpart of `released_status?/1`: keeps only meetings not released."
  @spec where_not_released(Ecto.Queryable.t()) :: Ecto.Query.t()
  def where_not_released(query) do
    where(query, [m], m.status not in ^@released_statuses)
  end

  @doc "Whether the meeting was cancelled."
  @spec cancelled?(Meeting.t() | map()) :: boolean()
  def cancelled?(%{status: status}), do: status == @cancelled

  @doc "Whether the meeting is a confirmed booking."
  @spec confirmed?(Meeting.t() | map()) :: boolean()
  def confirmed?(%{status: status}), do: status == @confirmed

  @doc """
  Whether the meeting expired: a request that lapsed unanswered (a booking
  request the host never answered, or a host's reschedule request the
  attendee never answered), or a paid booking whose payment completed after
  its slot was taken.
  """
  @spec expired?(Meeting.t() | map()) :: boolean()
  def expired?(%{status: status}), do: status == @expired

  @doc """
  Whether the meeting is over, one way or another (cancelled, completed or
  expired), so nothing may cancel, move or confirm it again. Struct-side
  counterpart of `where_not_terminal/1`.
  """
  @spec terminal?(Meeting.t()) :: boolean()
  def terminal?(%{status: status}), do: status in @terminal_statuses

  @doc """
  Composes onto `query` a filter keeping only meetings still in a status they
  can move on from, that is, not cancelled, completed or expired. A guarded
  transition writes through it so that, of two callers acting on the same
  meeting, only the first finds a row to change.
  """
  @spec where_not_terminal(Ecto.Queryable.t()) :: Ecto.Query.t()
  def where_not_terminal(query) do
    where(query, [m], m.status not in ^@terminal_statuses)
  end

  @doc """
  Query-side counterpart of `awaiting_approval?/1`.

  Deliberately does not compose `exclude_voided_slots/1`: a held request
  cannot carry a pending organizer reschedule request, because
  `Tymeslot.Bookings.Policy.can_request_reschedule?/1` refuses that action
  outright while the request awaits approval — the host has no reschedule
  action until they have approved it. Adding the filter would imply a state
  that cannot occur.
  """
  @spec where_awaiting_approval(Ecto.Queryable.t()) :: Ecto.Query.t()
  def where_awaiting_approval(query) do
    where(query, [m], m.status == @awaiting_approval)
  end

  @doc """
  Composes onto `query` a filter matching only booking requests that expired
  unanswered. Status `"expired"` also marks an abandoned paid checkout, which
  was never a request, so the request time must be set too.
  """
  @spec where_expired_request(Ecto.Queryable.t()) :: Ecto.Query.t()
  def where_expired_request(query) do
    where(query, [m], m.status == @expired and not is_nil(m.approval_requested_at))
  end

  @doc "Query-side negation of `awaiting_approval?/1`."
  @spec where_not_awaiting_approval(Ecto.Queryable.t()) :: Ecto.Query.t()
  def where_not_awaiting_approval(query) do
    where(query, [m], m.status != @awaiting_approval)
  end

  @doc """
  Composes onto `query` the contract "this is a live, confirmed booking a
  user should see as upcoming": `status == :confirmed` and no pending
  reschedule request. A meeting under a pending reschedule request has
  already had its calendar event deleted and its attendee told the
  appointment is cancelled, so it must not resurface here even though
  `status` is left untouched at `:confirmed`.
  """
  @spec where_live_booking(Ecto.Queryable.t()) :: Ecto.Query.t()
  def where_live_booking(query) do
    query
    |> where([m], m.status == ^@confirmed)
    |> exclude_voided_slots()
  end

  @doc "Whether the meeting is held until the attendee verifies their email address."
  @spec awaiting_verification?(Meeting.t() | map()) :: boolean()
  def awaiting_verification?(%{status: @awaiting_verification}), do: true
  def awaiting_verification?(_meeting), do: false

  @doc """
  Status counterpart of `awaiting_verification?/1`, for callers that hold the
  status alone (the themes' assigns).
  """
  @spec awaiting_verification_status?(status() | nil) :: boolean()
  def awaiting_verification_status?(@awaiting_verification), do: true
  def awaiting_verification_status?(_status), do: false

  @doc """
  Whether the booking was gated behind email verification and never verified:
  a deadline was set and `email_verified_at` is still empty. Read from the
  columns rather than `status`, so a held booking that expired unverified
  stays unverified.
  """
  @spec unverified?(Meeting.t() | map()) :: boolean()
  def unverified?(%{verification_deadline_at: %DateTime{}, email_verified_at: nil}), do: true
  def unverified?(_meeting), do: false

  @doc """
  Whether the organiser may see this meeting: the single definition of
  organiser visibility, mirrored for queries by `where_visible_to_organiser/1`.

  A booking held for email verification (`:awaiting_verification`) is
  hidden while it is held. That is nearly always also the first rule below,
  but not for a group slot held again once its last confirmed seat left
  beside seats still awaiting verification
  (`Tymeslot.Bookings.SeatRelease`): it keeps the `email_verified_at` of its
  first life, so that should it end held it stays in the organiser's history
  as the meeting they knew of.

  Two kinds of booking never reach the organiser, because neither became a
  booking anyone agreed to:

    * **Unverified**: `unverified?/1`, read from the verification columns, so
      a hold that expired without being verified stays hidden for good.
    * **Unpaid**: one that never got past payment. That is status
      `:awaiting_payment`, or `:expired` with no `approval_resolved_at`. The
      meeting row carries no payment column, so the second half reads what
      the other ways to `:expired` leave behind: an approval request that
      lapsed (or was answered after its deadline) is released by
      `Tymeslot.Meetings.Approval`, which always stamps
      `approval_resolved_at`, whereas a lapsed or failed checkout
      (`Tymeslot.MeetingPayments.HeldMeetings.expire/1`, `PaidBooking`, a
      refused late payment) writes the status alone. `approval_requested_at`
      cannot tell them apart, since a paid type that requires approval stamps
      it at submission, before any payment. Nor can the booking payment's
      `paid_at`: a checkout that failed to open leaves no payment row, and a
      late payment refused onto a slot already taken is paid without ever
      becoming a booking. A late payment that is recovered moves the meeting
      to `:confirmed` or `:awaiting_approval`, and from then on it is
      visible like any paid booking.

  A reschedule request that lapsed unanswered (`reschedule_request_lapsed?/2`)
  also ends `:expired` without `approval_resolved_at`, but it keeps its
  `reschedule_requested_at`, which only the host sets, from a booking they
  could see, so it stays visible.

  The remaining expiry, an unverified hold, also has no
  `approval_resolved_at`; both rules hide it.
  """
  @spec visible_to_organiser?(Meeting.t() | map()) :: boolean()
  def visible_to_organiser?(meeting),
    do: not awaiting_verification?(meeting) and not unverified?(meeting) and not unpaid?(meeting)

  defp unpaid?(%{status: @awaiting_payment}), do: true
  defp unpaid?(%{status: @expired, reschedule_requested_at: %DateTime{}}), do: false
  defp unpaid?(%{status: @expired, approval_resolved_at: nil}), do: true
  defp unpaid?(%{status: _status, approval_resolved_at: _resolved_at}), do: false

  @doc "Query-side counterpart of `awaiting_verification?/1`."
  @spec where_awaiting_verification(Ecto.Queryable.t()) :: Ecto.Query.t()
  def where_awaiting_verification(query) do
    where(query, [m], m.status == @awaiting_verification)
  end

  @doc "Negation of `where_awaiting_verification/1`: keeps only meetings not held for verification."
  @spec where_not_awaiting_verification(Ecto.Queryable.t()) :: Ecto.Query.t()
  def where_not_awaiting_verification(query) do
    where(query, [m], m.status != @awaiting_verification)
  end

  @doc """
  Query-side counterpart of `visible_to_organiser?/1`, and the same rule
  clause for clause: not held, verified or never gated, and past payment.
  Assumes the meeting is the query's first binding.
  """
  @spec where_visible_to_organiser(Ecto.Queryable.t()) :: Ecto.Query.t()
  def where_visible_to_organiser(query) do
    where(
      query,
      [m],
      m.status != @awaiting_verification and
        (is_nil(m.verification_deadline_at) or not is_nil(m.email_verified_at)) and
        m.status != @awaiting_payment and
        (m.status != @expired or not is_nil(m.approval_resolved_at) or
           not is_nil(m.reschedule_requested_at))
    )
  end
end
