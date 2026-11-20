defmodule Tymeslot.Bookings.SlotActivation do
  @moduledoc """
  The jobs a group seat owes once it counts, and the activation of a slot
  held for email verification when its first seat counts.

  A seat on a group slot owes a calendar job, its confirmation emails (the
  booker's and the organiser's seat email) and the integration fan-out. The
  seat that brings a slot to life also owes what the slot itself needs once:
  the calendar event's creation rather than an update, the reminders, and the
  video room, whose job then releases the seat's confirmation once the join
  link exists.

  Two callers decide differently which seat brings a slot to life.
  `Tymeslot.Bookings.CreateGroup` knows it from `book_seat/3`: the seat that
  created the meeting row. A slot held for email verification exists before
  any seat counts, so for a seat counting on an existing slot
  (`Tymeslot.Meetings.EmailVerification.verify_seat/1`, or an ungated seat
  joining a held slot) the slot's own status decides, read under its row lock:
  a slot still `:awaiting_verification` is confirmed now, and this seat owes
  the first-seat effects.
  """

  alias Tymeslot.Bookings.SeatEffects
  alias Tymeslot.Clock
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingTransitionQueries
  alias Tymeslot.Meetings.ParticipantSchema, as: Participant
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Notifications.Events.Seats

  # As the booking page books a seat: a slot's first seat makes its room for
  # any configured video provider.
  @booking_opts [with_video_room: true]

  @doc """
  Schedules the effects of a seat that now counts on an existing slot, inside
  the caller's transaction, and returns the integration fan-out to hand to
  `Tymeslot.Bookings.Activation.after_commit/1` once it has committed.

  The slot is re-read under its row lock, whatever the caller's copy says, so
  that two seats counting at once cannot both run the first-seat effects. A
  slot `:awaiting_verification` is confirmed (`email_verified_at` stamped) and
  the seat owes the first-seat effects; any other slot, a planned session
  included, is already live and the seat owes only its own.

  `opts` are as for `schedule_seat_effects/4`, defaulting to the booking
  page's (a first seat makes the slot's video room).
  """
  @spec activate_seat_in_transaction(Meeting.t(), Participant.t(), keyword()) ::
          {:ok, Events.pending()} | {:error, term()}
  def activate_seat_in_transaction(
        %Meeting{id: slot_id},
        %Participant{} = participant,
        opts \\ @booking_opts
      ) do
    with {:ok, slot} <- MeetingQueries.get_meeting_for_update(slot_id) do
      activate_locked(slot, participant, opts)
    end
  end

  defp activate_locked(%Meeting{status: :awaiting_verification} = slot, participant, opts) do
    changes = [status: :confirmed, email_verified_at: DateTime.truncate(Clock.utc_now(), :second)]

    with {:ok, confirmed} <-
           MeetingTransitionQueries.transition_from_awaiting_verification(slot.id, changes) do
      schedule_seat_effects(confirmed, participant, true, opts)
    end
  end

  defp activate_locked(slot, participant, opts),
    do: schedule_seat_effects(slot, participant, false, opts)

  @doc """
  Schedules a counting seat's jobs inside the caller's transaction: the
  calendar job (`"create"` for the seat that brings the slot to life,
  `"update"` otherwise), the slot's reminders and video room for that first
  seat, and the seat's confirmation emails, unless the room's job is to
  release them. Returns the seat's integration fan-out, to be dispatched once
  the transaction has committed; any error is the caller's cue to roll back.

  `opts` are passed to `SeatEffects.schedule_new_slot_effects/2`
  (`:with_video_room`), besides `:emails`: `false` sends no confirmation for
  the seat, to the booker or the host, and returns no fan-out, as for a seat
  of a booking series, which is announced whole
  (`Tymeslot.BookingSeries.Automation`). A slot such a seat brings to life
  still gets its reminders and video room, the room holding nothing back.
  """
  @spec schedule_seat_effects(Meeting.t(), Participant.t(), boolean(), keyword()) ::
          {:ok, Events.pending()} | {:error, term()}
  def schedule_seat_effects(meeting, participant, first_seat?, opts) do
    emails? = Keyword.get(opts, :emails, true)

    with {:ok, _job} <- SeatEffects.schedule_calendar_job(meeting, first_seat?),
         {:ok, defer_emails?} <- schedule_new_slot_effects(first_seat?, meeting, emails?, opts),
         {{:ok, _scheduled}, pending} <-
           Seats.seat_booked_deferred(meeting, participant,
             defer_emails?: defer_emails?,
             emails: emails?,
             integrations: emails?
           ) do
      {:ok, pending}
    else
      {{:error, reason}, _pending} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp schedule_new_slot_effects(false, _meeting, _emails?, _opts), do: {:ok, false}

  defp schedule_new_slot_effects(true, meeting, emails?, opts),
    do: SeatEffects.schedule_new_slot_effects(meeting, Keyword.put(opts, :announce, emails?))
end
