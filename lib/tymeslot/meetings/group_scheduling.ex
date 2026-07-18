defmodule Tymeslot.Meetings.GroupScheduling do
  @moduledoc """
  Seat booking for group meeting types (`max_participants > 1`).

  One meeting row holds a slot; each booker is a `meeting_participants` row
  and a booker's guests count towards the seats. `book_seat/3` runs one
  transaction per attempt:

    * an existing live meeting for `(meeting_type_id, start_time)` is locked
      `FOR UPDATE`, the seat count is re-checked under the lock, and the
      participant plus guests are inserted, or the transaction rolls back
      with `{:error, :slot_full}`;
    * with no live meeting, the meeting is created through the standard
      buffered `FOR UPDATE NOWAIT` conflict-checked path together with the
      first participant.

  Two racing first bookers are resolved by the partial unique index on
  `(organizer_user_id, start_time) where status = 'confirmed'`: the loser's
  insert fails the constraint, the transaction rolls back, and one retry
  runs down the join path against the winner's now-visible row.
  """

  alias Ecto.Changeset
  alias Tymeslot.Meetings.GroupMeetingQueries
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Meetings.Scheduling
  alias Tymeslot.Meetings.Seats
  alias Tymeslot.Repo

  @unique_slot_constraint "unique_confirmed_meeting_per_organizer_at_time"

  @typedoc "One booker's request for seats at a slot."
  @type seat_request :: %{
          required(:participant) => map(),
          required(:guest_emails) => [String.t()],
          required(:max_participants) => pos_integer()
        }

  @typedoc "A successfully booked seat."
  @type booking :: %{
          meeting: Meeting.t(),
          participant: ParticipantSchema.t(),
          created_meeting?: boolean()
        }

  @doc """
  Books one participant (plus their guests) onto the group slot described by
  `meeting_attrs` (`:meeting_type_id` and `:start_time` identify the slot).

  Options:
    * `:on_booked` — a function `(booking -> {:ok, term} | {:error, term})`
      run inside the transaction after the seat is taken; an error return
      rolls the whole seat back. Used by the booking flow to enqueue the
      calendar-event job atomically with the seat.

  Returns `{:ok, booking}` or `{:error, :slot_full | :time_conflict |
  Ecto.Changeset.t() | term}`.
  """
  @spec book_seat(map(), seat_request(), keyword()) ::
          {:ok, booking()} | {:error, :slot_full | :time_conflict | Changeset.t() | term()}
  def book_seat(meeting_attrs, seat_request, opts \\ []) do
    seats_requested = 1 + length(seat_request.guest_emails)
    on_booked = Keyword.get(opts, :on_booked, fn _booking -> {:ok, :noop} end)

    if seats_requested > seat_request.max_participants do
      {:error, :slot_full}
    else
      attempt_booking(meeting_attrs, seat_request, seats_requested, on_booked, _retries_left = 1)
    end
  end

  defp attempt_booking(meeting_attrs, seat_request, seats_requested, on_booked, retries_left) do
    result =
      Repo.transaction(fn ->
        live_meeting =
          GroupMeetingQueries.get_live_for_update(
            meeting_attrs.meeting_type_id,
            meeting_attrs.start_time
          )

        booking =
          case live_meeting do
            nil ->
              create_meeting_with_first_seat(meeting_attrs, seat_request)

            %Meeting{} = meeting ->
              join_meeting(meeting, seat_request, seats_requested)
          end

        run_on_booked(booking, on_booked)
      end)

    case result do
      {:ok, booking} ->
        {:ok, booking}

      {:error, {:validation_error, %Changeset{} = changeset}} ->
        if lost_first_booker_race?(changeset) and retries_left > 0 do
          attempt_booking(
            meeting_attrs,
            seat_request,
            seats_requested,
            on_booked,
            retries_left - 1
          )
        else
          {:error, changeset}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_meeting_with_first_seat(meeting_attrs, seat_request) do
    case Scheduling.create_group_meeting_with_conflict_check(meeting_attrs) do
      {:ok, meeting} ->
        participant = insert_participant_or_rollback(meeting, seat_request)
        %{meeting: meeting, participant: participant, created_meeting?: true}

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp join_meeting(meeting, seat_request, seats_requested) do
    seats_taken = Seats.seats_taken(meeting.id)

    if seats_taken + seats_requested > seat_request.max_participants do
      Repo.rollback(:slot_full)
    else
      participant = insert_participant_or_rollback(meeting, seat_request)
      %{meeting: meeting, participant: participant, created_meeting?: false}
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

  defp run_on_booked(booking, on_booked) do
    case on_booked.(booking) do
      {:ok, _result} -> booking
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc """
  True when a changeset's error is the loser's side of the first-booker race
  on `(organizer_user_id, start_time)` — the partial unique index this module
  relies on to serialise two concurrent first bookings of the same slot.

  Exposed so callers outside this module (the booking flow's error
  classification) can recognise the same race without duplicating the
  constraint name.
  """
  @spec lost_first_booker_race?(Changeset.t()) :: boolean()
  def lost_first_booker_race?(%Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, error_opts}} ->
      error_opts[:constraint] == :unique and
        to_string(error_opts[:constraint_name] || "") == @unique_slot_constraint
    end)
  end
end
