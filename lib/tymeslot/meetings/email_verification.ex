defmodule Tymeslot.Meetings.EmailVerification do
  @moduledoc """
  The email verification gate: a booking on a meeting type that requires it is
  held until the attendee confirms their address through an emailed link.

  While held (`:awaiting_verification`) the booking occupies its slot against
  every other booking, but nothing else happens: the organiser learns nothing
  about it until `verify/1` succeeds. No emails, webhooks, calendar event,
  video room, dashboard listing, counts or analytics. Verification then moves
  the booking on exactly as an ungated booking would have gone: confirmed, or
  held for the host's approval.

  Every exit from the gate (verifying, expiring) is a guarded transition,
  `Tymeslot.Meetings.MeetingQueries.transition_from_awaiting_verification/2`,
  so the exits race one another safely and only one wins.

  A manual-approval type's approval clock starts at verification, not at
  submission: the host is only asked once the attendee has proved the address,
  so the window they are promised runs from that moment
  (`Tymeslot.Meetings.Approval.request_attributes/3`).
  """

  alias Tymeslot.MeetingTypes.MeetingTypeSchema, as: MeetingType

  # Fixed rather than per meeting type: the verification email promises this
  # window, and the slot is held from everyone else for as long as it runs.
  @hold_minutes 30

  @doc "Whether bookings on this meeting type must be verified by email."
  @spec required?(MeetingType.t() | map() | nil) :: boolean()
  def required?(%{requires_email_verification: true}), do: true
  def required?(_meeting_type), do: false

  @doc "How long an unverified booking holds its slot, in minutes."
  @spec hold_minutes() :: pos_integer()
  def hold_minutes, do: @hold_minutes

  @doc """
  When a booking made at `requested_at` stops being verifiable.

  Never later than the meeting's own start time: a slot that has begun cannot
  be given away.
  """
  @spec deadline_for(DateTime.t(), DateTime.t()) :: DateTime.t()
  def deadline_for(%DateTime{} = requested_at, %DateTime{} = start_time) do
    hold_end = DateTime.add(requested_at, @hold_minutes * 60, :second)
    earliest = if DateTime.compare(hold_end, start_time) == :lt, do: hold_end, else: start_time

    DateTime.truncate(earliest, :second)
  end

  @doc """
  The attributes a gated booking is created with: held, with its deadline, and
  the approval fields left unstamped until verification.
  """
  @spec gate_attributes(DateTime.t(), DateTime.t()) :: map()
  def gate_attributes(%DateTime{} = now, %DateTime{} = start_time) do
    %{
      status: :awaiting_verification,
      verification_deadline_at: deadline_for(now, start_time),
      approval_requested_at: nil,
      approval_deadline_at: nil
    }
  end
end
