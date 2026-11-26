defmodule Tymeslot.Meetings.SeatWrites do
  @moduledoc """
  The writes that take a seat on a group slot, shared by
  `Tymeslot.Meetings.GroupScheduling.book_seat/3` and
  `Tymeslot.Meetings.SeatHoldConversion`: creating the slot with its first
  seat, joining a live one, inserting the participant or the hold, and
  confirming a slot a hold created.

  Call with the organiser's schedule lock and the meeting row lock held.
  Every refusal here rolls the surrounding transaction back
  (`Repo.rollback/1`); a caller that must refuse without aborting decides so
  before calling in, by the same `joinable?/3` and `registration_open?/1`
  rules.
  """

  alias Ecto.Changeset
  alias Tymeslot.ContentTranslations.AttendeeTexts
  alias Tymeslot.Meetings.GroupMeetingQueries
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Meetings.PlannedSessions
  alias Tymeslot.Meetings.Scheduling
  alias Tymeslot.Meetings.SeatHoldQueries
  alias Tymeslot.Meetings.SeatHoldSchema
  alias Tymeslot.Meetings.Seats
  alias Tymeslot.Repo

  @hold_snapshot_fields ~w(name email phone company message timezone locale custom_field_answers)a

  @doc """
  Joins `live_meeting`, or creates the slot from `meeting_attrs` when there
  is none (`nil`), taking `seats_requested` seats for `seat_request`.

  `hooks` carries `:join_only` (no slot to join refuses as `:slot_full`),
  `:hold` (`nil`, or `%{expires_at: _}` to take a hold rather than a
  participant), `:exclude_from_conflicts` (as for `book_seat/3`) and
  `:registration_reserved?`: true when the seats were held on
  `live_meeting` before its registration closed (a paid hold converting
  there), so a closed registration does not refuse them.
  Returns the booking map; every refusal rolls back.
  """
  @spec take_seat(Meeting.t() | nil, map(), map(), pos_integer(), map()) :: map()
  def take_seat(nil, _meeting_attrs, _seat_request, _seats_requested, %{join_only: true}),
    do: Repo.rollback(:slot_full)

  def take_seat(nil, meeting_attrs, seat_request, seats_requested, hooks),
    do: create_meeting_with_first_seat(meeting_attrs, seat_request, seats_requested, hooks)

  def take_seat(%Meeting{} = meeting, meeting_attrs, seat_request, seats_requested, hooks) do
    meeting
    |> join_meeting(seat_request, seats_requested, hooks)
    |> add_attendee_texts(meeting_attrs)
  end

  @doc """
  Runs the caller's `on_booked` callback on `booking`, putting its result
  under `:on_booked_result`; an error return rolls the transaction back.
  """
  @spec run_on_booked(map(), (map() -> {:ok, term()} | {:error, term()})) :: map()
  def run_on_booked(booking, on_booked) do
    case on_booked.(booking) do
      {:ok, result} -> Map.put(booking, :on_booked_result, result)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc """
  Whether a live meeting takes `seats_requested` more seats, counting its
  current seats (or `seats_left`, when the caller has counted them).

  A solo meeting at the slot (a one-to-one booked before the type became a
  group type) is never joined: it reads as full, so a private booking stays
  private.
  """
  @spec joinable?(Meeting.t(), pos_integer()) :: boolean()
  def joinable?(meeting, seats_requested),
    do: joinable?(meeting, seats_requested, Seats.seats_left(meeting, meeting.capacity))

  @spec joinable?(Meeting.t(), pos_integer(), integer()) :: boolean()
  def joinable?(meeting, seats_requested, seats_left),
    do: Meeting.group?(meeting) and seats_requested <= seats_left

  @doc "Whether a meeting still takes bookings: a planned session only until its registration closes."
  @spec registration_open?(Meeting.t()) :: boolean()
  def registration_open?(%Meeting{planned: true} = session), do: PlannedSessions.open?(session)
  def registration_open?(%Meeting{}), do: true

  @doc "The booker fields a seat hold snapshots from a participant, and gives back on conversion."
  @spec hold_snapshot(map()) :: map()
  def hold_snapshot(source), do: Map.take(source, @hold_snapshot_fields)

  # A slot is created confirmed, awaiting payment when a hold creates it, or
  # awaiting verification when its first seat is held for an email check
  # (`MeetingSchema.group_changeset/2` honours no other status).
  defp create_meeting_with_first_seat(meeting_attrs, seat_request, seats_requested, hooks) do
    # Snapshotted once, at creation, onto the meeting row itself — see
    # `Tymeslot.Meetings.group?/1`. Not re-read from the meeting type later.
    attrs =
      Map.merge(meeting_attrs, %{
        capacity: seat_request.max_participants,
        status: slot_status(meeting_attrs, hooks)
      })

    case Scheduling.create_group_meeting_with_conflict_check(attrs,
           exclude_uid: hooks.exclude_from_conflicts.()
         ) do
      {:ok, meeting} ->
        meeting
        |> insert_seat_or_rollback(seat_request, seats_requested, hooks.hold)
        |> Map.merge(%{meeting: meeting, created_meeting?: true})

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  # Only a hold creates a slot awaiting payment; a caller's status never does.
  defp slot_status(_meeting_attrs, %{hold: hold}) when hold not in [nil, false],
    do: :awaiting_payment

  defp slot_status(%{status: :awaiting_verification}, _hooks), do: :awaiting_verification
  defp slot_status(_meeting_attrs, _hooks), do: :confirmed

  # Gates on the meeting's own capacity, not the caller's
  # `seat_request.max_participants` (which is only the correct capacity for
  # a meeting not yet created, see `create_meeting_with_first_seat/4`); the
  # type keeps a group meeting's capacity in step with its limit. A planned
  # session's registration close is re-read here, on the locked row, for the
  # same reason the seats are: the caller's pre-check read it unlocked. Seats
  # reserved on the meeting before the close skip it.
  defp join_meeting(meeting, seat_request, seats_requested, hooks) do
    if joinable?(meeting, seats_requested) and
         (hooks.registration_reserved? or registration_open?(meeting)) do
      seat = insert_seat_or_rollback(meeting, seat_request, seats_requested, hooks.hold)

      {meeting, confirmed?} = settle_awaiting_payment(meeting, seat)

      Map.merge(seat, %{meeting: meeting, created_meeting?: confirmed?})
    else
      Repo.rollback(:slot_full)
    end
  end

  # A slot a hold created stays `:awaiting_payment` until its first seat
  # that counts, a free seat joining it or a paid hold converting. That is
  # when the slot comes into being for the seat's callers: it has no
  # calendar event, reminders or video room yet, so the seat reports
  # `created_meeting?: true` and they schedule them. A seat awaiting email
  # verification does not count yet, so it holds the slot for verification
  # instead, as a slot its first seat creates held is: verifying it brings
  # the slot to life (`Tymeslot.Bookings.SlotActivation`), and until then
  # nobody but its bookers knows of the slot. Another hold changes nothing.
  # Call with the meeting row locked. Returns the meeting and whether it was
  # confirmed now.
  defp settle_awaiting_payment(%Meeting{status: :awaiting_payment} = meeting, %{
         participant: participant
       }) do
    result =
      if ParticipantSchema.unverified?(participant),
        do:
          GroupMeetingQueries.hold_awaiting_payment_for_verification(
            meeting,
            participant.verification_deadline_at
          ),
        else: GroupMeetingQueries.confirm_awaiting_payment(meeting)

    case result do
      {:ok, %Meeting{status: :confirmed} = confirmed} -> {confirmed, true}
      {:ok, held} -> {held, false}
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp settle_awaiting_payment(%Meeting{} = meeting, _seat), do: {meeting, false}

  # The joiner read the slot in their own language: their locale's copy of
  # its texts joins the slot's (`AttendeeTexts.merge/2`), under the lock
  # taken above, so two joiners in different languages cannot overwrite
  # each other's copy.
  defp add_attendee_texts(%{meeting: meeting} = booking, meeting_attrs) do
    case AttendeeTexts.merge(meeting, meeting_attrs) do
      texts when texts == meeting.attendee_texts ->
        booking

      texts ->
        case GroupMeetingQueries.set_attendee_texts(meeting, texts) do
          {:ok, updated} -> %{booking | meeting: updated}
          {:error, changeset} -> Repo.rollback(changeset)
        end
    end
  end

  # Checked under the meeting's row lock, before either insert: the seat's
  # own unique index sees only its own table, so a held email booking a free
  # seat (or the reverse) would otherwise pass it. The indexes stay the
  # backstop within each table. A seat is `:already_booked`; a hold is
  # `:seat_held`, a checkout the booker left open and can still finish.
  defp insert_seat_or_rollback(meeting, seat_request, seats_requested, hold_opts) do
    case email_taken(meeting.id, seat_request.participant.email) do
      nil -> :ok
      reason -> Repo.rollback(reason)
    end

    case hold_opts do
      nil ->
        %{participant: insert_participant_or_rollback(meeting, seat_request)}

      %{expires_at: _expires_at} ->
        %{seat_hold: insert_hold_or_rollback(meeting, seat_request, seats_requested, hold_opts)}
    end
  end

  defp email_taken(_meeting_id, nil), do: nil

  defp email_taken(meeting_id, email) do
    cond do
      ParticipantQueries.live_email_taken?(meeting_id, email) -> :already_booked
      SeatHoldQueries.held_email_taken?(meeting_id, email) -> :seat_held
      true -> nil
    end
  end

  defp insert_hold_or_rollback(meeting, seat_request, seats_requested, %{expires_at: expires_at}) do
    attrs =
      seat_request.participant
      |> hold_snapshot()
      |> Map.merge(%{
        meeting_id: meeting.id,
        meeting_type_id: meeting.meeting_type_id,
        start_time: meeting.start_time,
        seats: seats_requested,
        guests: Enum.map(seat_request.guest_emails, &%{"name" => nil, "email" => &1}),
        expires_at: expires_at
      })

    case SeatHoldQueries.insert(attrs) do
      {:ok, hold} ->
        hold

      {:error, %Changeset{} = changeset} ->
        if SeatHoldSchema.duplicate_hold?(changeset),
          do: Repo.rollback(:seat_held),
          else: Repo.rollback(changeset)
    end
  end

  defp insert_participant_or_rollback(meeting, seat_request) do
    attrs = Map.put(seat_request.participant, :meeting_id, meeting.id)

    with {:ok, participant} <- ParticipantQueries.insert(attrs),
         {:ok, _guests} <-
           Guests.create_for_participant(meeting.id, participant.id, seat_request.guest_emails) do
      participant
    else
      {:error, %Changeset{} = changeset} -> Repo.rollback(changeset)
    end
  end
end
