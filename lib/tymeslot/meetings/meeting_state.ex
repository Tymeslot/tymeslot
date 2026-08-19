defmodule Tymeslot.Meetings.MeetingState do
  @moduledoc """
  Single owner of predicates derived from a meeting's two independent state
  axes: `status` (the booking lifecycle — pending, awaiting_payment,
  awaiting_approval, confirmed, cancelled, completed) and
  `reschedule_requested_at` (whether the organizer is currently awaiting the
  attendee to pick a new time). The two axes are orthogonal: an organizer
  reschedule request no longer overwrites `status`, so a `pending` or
  `awaiting_payment` meeting keeps that status while a request is pending.

  `status == "reschedule_requested"` is a legacy value: no code writes it any
  more, but it remains a valid enum member so historical (or unmigrated) rows
  keep reading correctly here.
  """

  import Ecto.Query, warn: false

  alias Tymeslot.Meetings.MeetingSchema, as: Meeting

  @active_statuses ["confirmed", "pending", "awaiting_approval", "reschedule_requested"]

  # Statuses that occupy a calendar slot for conflict-detection purposes.
  # Combined with `exclude_voided_slots/1`, this is the query-side mirror of
  # `slot_void?/1`: a meeting only actually blocks a time window while it
  # holds one of these statuses AND has no pending reschedule request.
  @occupying_statuses ["confirmed", "pending", "awaiting_payment", "awaiting_approval"]

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
  def slot_void?(%{status: "cancelled"}), do: true
  def slot_void?(%{status: "reschedule_requested"}), do: true
  def slot_void?(%{reschedule_requested_at: nil}), do: false
  def slot_void?(%{reschedule_requested_at: %DateTime{}}), do: true

  @doc """
  Whether a provider calendar event should still exist for this meeting.
  Answers a different question from `active?/1` and `slot_void?/1`: `active?`
  is "may a user interact with it", `slot_void?` is "does its time slot
  still hold", and this is "should we expect a provider event on the
  organizer's calendar right now". A meeting can be active yet have a void
  slot (an organizer reschedule request pending, or the legacy
  `"reschedule_requested"` status) — in that case we deliberately deleted or
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
  time for this meeting.
  """
  @spec awaiting_new_time?(Meeting.t()) :: boolean()
  def awaiting_new_time?(%{status: "reschedule_requested"}), do: true
  def awaiting_new_time?(%{reschedule_requested_at: %DateTime{}}), do: true
  def awaiting_new_time?(_meeting), do: false

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
  Query-side counterpart of `awaiting_new_time?/1`: excludes meetings whose
  slot is currently voided by a pending reschedule request. Compose this
  directly (rather than `where_slot_live/1`) when the caller applies its own
  status filter, e.g. reminder eligibility only ever considers `"confirmed"`.
  """
  @spec exclude_voided_slots(Ecto.Queryable.t()) :: Ecto.Query.t()
  def exclude_voided_slots(query) do
    where(query, [m], is_nil(m.reschedule_requested_at))
  end

  @doc """
  Whether the meeting is held pending the host's manual approval.

  Distinct from `awaiting_new_time?/1`: there the organizer is waiting on the
  attendee, here the attendee is waiting on the organizer.
  """
  @spec awaiting_approval?(Meeting.t()) :: boolean()
  def awaiting_approval?(%{status: "awaiting_approval"}), do: true
  def awaiting_approval?(_meeting), do: false

  @doc """
  Query-side counterpart of `awaiting_approval?/1`.

  Deliberately does not compose `exclude_voided_slots/1`: a held request
  cannot carry a pending organizer reschedule request, because the host is
  offered no reschedule action until they have approved the booking. Adding
  the filter would imply a state that cannot occur.
  """
  @spec where_awaiting_approval(Ecto.Queryable.t()) :: Ecto.Query.t()
  def where_awaiting_approval(query) do
    where(query, [m], m.status == "awaiting_approval")
  end

  @doc """
  Composes onto `query` the contract "this is a live, confirmed booking a
  user should see as upcoming": `status == "confirmed"` and no pending
  reschedule request. A meeting under a pending reschedule request has
  already had its calendar event deleted and its attendee told the
  appointment is cancelled, so it must not resurface here even though
  `status` is left untouched at `"confirmed"`.
  """
  @spec where_live_booking(Ecto.Queryable.t()) :: Ecto.Query.t()
  def where_live_booking(query) do
    query
    |> where([m], m.status == "confirmed")
    |> exclude_voided_slots()
  end
end
