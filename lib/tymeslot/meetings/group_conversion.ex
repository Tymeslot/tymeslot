defmodule Tymeslot.Meetings.GroupConversion do
  @moduledoc """
  Migrates a meeting type's existing bookings when it becomes a group type.

  A solo booking lives in the meeting row's `attendee_*` columns; a group
  booking lives in `meeting_participants`. Switching `max_participants` from
  1 to more than 1 does not move anything on its own, which leaves the
  existing bookings in the wrong shape for every group code path: seat maths
  counts participant rows, so the sitting attendee's seat reads as free and
  a stranger joins their 1:1; and the notification recipients for a meeting
  with participants would no longer include them.

  `backfill/1` closes that gap by giving every future booking of the type a
  participant row built from its own attendee columns, and re-pointing that
  booking's guests at the new participant so their seats count too. The
  attendee columns are left in place: they are what the meeting was booked
  with, and `Tymeslot.Meetings.Recipient.for_meeting/1` unions both shapes
  precisely so a half-converted row is still safe.

  Runs off the request path, inside `Tymeslot.Workers.GroupConversionWorker`.
  Bookings are processed in batches, each in its own transaction, so a job
  never holds a single unbounded transaction open; a batch that hits a
  genuine conversion failure halts there and returns `{:error, _}`, which
  fails the job so Oban retries it. A retry is safe: a meeting that already
  converted on an earlier attempt is skipped, not reprocessed. Touches only
  future, non-cancelled meetings — past bookings are history and need no
  seat accounting.
  """

  require Logger

  alias Tymeslot.Clock
  alias Tymeslot.Meetings.GroupMeetingQueries
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Repo

  @batch_size 100

  @doc """
  Backfills participant rows for the future bookings of `meeting_type_id`,
  and snapshots `capacity` onto every converted meeting row.

  Returns the number of bookings converted so far. Meetings that already
  carry a participant are skipped. A booking that fails to convert halts
  the run and returns `{:error, _}` rather than silently skipping it — the
  caller (the worker) retries, which resumes from the first unconverted
  booking since everything before it is now skip-eligible.
  """
  @spec backfill(integer(), pos_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def backfill(meeting_type_id, capacity)
      when is_integer(meeting_type_id) and is_integer(capacity) do
    meeting_type_id
    |> GroupMeetingQueries.list_convertible_solo_bookings(Clock.utc_now())
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce_while({:ok, 0}, fn batch, {:ok, total} ->
      case convert_batch(batch, capacity) do
        {:ok, converted} -> {:cont, {:ok, total + converted}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp convert_batch(batch, capacity) do
    Repo.transaction(fn ->
      Enum.reduce_while(batch, 0, fn meeting, converted ->
        case convert(meeting, capacity) do
          {:ok, :converted} -> {:cont, converted + 1}
          {:ok, :skipped} -> {:cont, converted}
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end)
  end

  defp convert(meeting, capacity) do
    if ParticipantQueries.count_live_for_meeting(meeting.id) > 0 do
      {:ok, :skipped}
    else
      insert_participant(meeting, capacity)
    end
  end

  defp insert_participant(meeting, capacity) do
    case ParticipantQueries.insert(participant_attrs(meeting)) do
      {:ok, participant} ->
        # Guests booked before the switch have no participant of their own, so
        # they count for nothing in seat maths until they are adopted.
        GuestQueries.adopt_unowned_guests(meeting.id, participant.id)
        snapshot_capacity(meeting, capacity)
        {:ok, :converted}

      {:error, changeset} ->
        # Left unconverted, this booking's attendee columns are still safe —
        # `Tymeslot.Meetings.Recipient.for_meeting/1` unions both shapes — but
        # its seat reads as empty until a retry converts it, so the failure
        # must not be swallowed here.
        Logger.error("Failed to convert solo booking to a group seat",
          meeting_id: meeting.id,
          errors: inspect(changeset.errors)
        )

        {:error, {:participant_insert_failed, meeting.id}}
    end
  end

  # The row was created solo (capacity 1); now that it genuinely holds a
  # group of participants, its capacity must say so — otherwise
  # `Tymeslot.Meetings.group?/1` keeps reading it as solo forever.
  defp snapshot_capacity(meeting, capacity) do
    case MeetingQueries.update_meeting(meeting, %{capacity: capacity}) do
      {:ok, _updated} ->
        :ok

      {:error, changeset} ->
        Logger.error("Failed to snapshot capacity on converted booking",
          meeting_id: meeting.id,
          errors: inspect(changeset.errors)
        )

        :ok
    end
  end

  defp participant_attrs(meeting) do
    %{
      meeting_id: meeting.id,
      name: meeting.attendee_name,
      email: meeting.attendee_email,
      phone: meeting.attendee_phone,
      company: meeting.attendee_company,
      message: meeting.attendee_message,
      timezone: meeting.attendee_timezone,
      locale: meeting.attendee_locale || "en",
      custom_field_answers: meeting.custom_field_answers || %{}
    }
  end
end
