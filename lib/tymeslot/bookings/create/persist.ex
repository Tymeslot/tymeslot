defmodule Tymeslot.Bookings.Create.Persist do
  @moduledoc """
  Writing one booked meeting and the work it owes, inside the caller's
  transaction: the meeting itself (conflict-checked under the organiser's
  schedule lock), the booker's guests, the calendar job, and the activation
  (`Tymeslot.Bookings.Activation.activate_in_transaction/2`).

  Shared by `Tymeslot.Bookings.Create`, for a booking of its own, and
  `Tymeslot.BookingSeries.Create`, for each session of a series, so the two
  cannot take the steps differently. The caller owns the transaction and
  rolls it back on an error; the integration fan-out returned is run after
  its commit.
  """

  alias Tymeslot.Bookings.{Activation, CalendarJobs, Policy}
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.Scheduling
  alias Tymeslot.Meetings.UniqueInvitation
  alias Tymeslot.Notifications.Events

  @doc """
  Writes the meeting and every job it owes. Returns the meeting and the
  integration fan-out still owed, or the first step's error, after which
  the caller must roll its transaction back: the step has already left it
  unable to commit.

  `activation_opts` are `Activation.activate_in_transaction/2`'s.
  """
  @spec persist_and_activate(map(), map(), keyword()) ::
          {:ok, {MeetingSchema.t(), Events.pending()}} | {:error, term()}
  def persist_and_activate(meeting_attrs, booking_data, activation_opts) do
    with {:ok, meeting} <- create_meeting(meeting_attrs),
         {:ok, _guests} <- create_guests(meeting, booking_data),
         {:ok, _result} <- CalendarJobs.schedule_job(meeting, "create"),
         {:ok, pending} <- Activation.activate_in_transaction(meeting, activation_opts) do
      {:ok, {meeting, pending}}
    end
  end

  @doc """
  Inserts the meeting under the organiser's schedule lock, refusing a
  conflict or a booking limit reached.

  A booking that lost its invitation to another one committed first (both
  passed the invitation pre-check, serialised on the organiser's schedule
  lock), or whose invitation was deleted since, is refused by the database
  at insert, not by the pre-check.
  """
  @spec create_meeting(map()) :: {:ok, MeetingSchema.t()} | {:error, term()}
  def create_meeting(meeting_attrs) do
    case Scheduling.create_meeting_with_conflict_check(meeting_attrs) do
      {:ok, meeting} ->
        {:ok, meeting}

      {:error, {:validation_error, changeset}} ->
        if UniqueInvitation.unavailable?(changeset),
          do: {:error, :invitation_unavailable},
          else: {:error, :validation_error}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Persists the attendee-added guests, but only when the meeting type allows
  guests. Sanitisation (format, de-dup, self-exclusion, cap) is re-applied
  here server-side: the client list is never trusted. Runs inside the
  booking transaction so a guest failure rolls the whole booking back.
  """
  @spec create_guests(MeetingSchema.t(), map()) :: {:ok, list()} | {:error, term()}
  def create_guests(meeting, booking_data) do
    if Policy.guests_allowed?(booking_data) do
      booking_data
      |> Map.get(:guest_emails, [])
      |> Guests.sanitize_emails(
        meeting.attendee_email,
        Guests.limit_for(Map.get(booking_data, :meeting_type))
      )
      |> then(&Guests.create_for_meeting(meeting.id, &1, :booker))
    else
      {:ok, []}
    end
  end
end
