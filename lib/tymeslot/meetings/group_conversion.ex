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
  never holds a single unbounded transaction open. A booking whose stored
  data cannot satisfy today's participant rules (a pre-migration row with no
  attendee timezone, say) is logged and left unconverted rather than rolling
  back everyone else's conversion in the same batch — see `insert_participant/2`.
  Touches only future, non-cancelled meetings — past bookings are history and
  need no seat accounting.

  Re-runs safely: a meeting that already carries its converted attendee as a
  live participant, and nobody else, is left alone unless `capacity` has
  changed since — in which case it is re-stamped, which is what lets an
  organiser's capacity correction (edited again shortly after the first
  save, before anyone else has booked in) land instead of being silently
  lost. A meeting with more than one live participant has taken real
  bookings against its snapshotted capacity and is never touched again.
  """

  require Logger

  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings.GroupMeetingQueries
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.SeatBroadcast
  alias Tymeslot.Notifications.Orchestrator
  alias Tymeslot.Profiles
  alias Tymeslot.Repo

  @batch_size 100

  @doc """
  Backfills participant rows for the future bookings of `meeting_type_id`,
  and snapshots `capacity` onto every converted (or re-converted, see the
  module doc) meeting row.

  Returns the number of bookings newly given a participant row. Always
  succeeds: a booking that cannot convert is logged and skipped rather than
  failing the run, so one poisoned row cannot strand the rest of the type's
  bookings.
  """
  @spec backfill(integer(), pos_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def backfill(meeting_type_id, capacity)
      when is_integer(meeting_type_id) and is_integer(capacity) do
    meetings =
      GroupMeetingQueries.list_convertible_solo_bookings(meeting_type_id, Clock.utc_now())

    result =
      meetings
      |> Enum.chunk_every(@batch_size)
      |> Enum.reduce({:ok, 0}, fn batch, {:ok, total} ->
        {:ok, converted} = convert_batch(batch, capacity)
        {:ok, total + converted}
      end)

    # Capacity and seat counts just moved for every meeting above, live pages
    # and the availability cache must not keep serving the pre-conversion
    # answer. `GuestQueries.adopt_unowned_guests/2` (called per booking below)
    # changes seat counts the same way and shares this same invalidation.
    invalidate_after_conversion(meetings)

    result
  end

  defp invalidate_after_conversion([]), do: :ok

  defp invalidate_after_conversion([meeting | _rest]) do
    AvailabilityCache.invalidate_for_user(meeting.organizer_user_id)
    SeatBroadcast.broadcast_seat_change(meeting.meeting_type_id)
    :ok
  end

  defp convert_batch(batch, capacity) do
    Repo.transaction(fn ->
      Enum.reduce(batch, 0, fn meeting, converted ->
        case convert(meeting, capacity) do
          {:ok, :converted} -> converted + 1
          {:ok, _skipped_or_recapacitated} -> converted
        end
      end)
    end)
  end

  defp convert(meeting, capacity) do
    case ParticipantQueries.count_live_for_meeting(meeting.id) do
      0 ->
        insert_participant(meeting, capacity)

      1 ->
        # Already converted, and still only the attendee that conversion
        # itself put there — nobody has booked a real seat against the
        # snapshotted capacity yet, so a corrected capacity is still safe to
        # apply. A fresh group meeting never reaches here: it is created
        # together with its first participant and carries no attendee_email
        # (see `list_convertible_solo_bookings/2`), so it is never in `batch`.
        recapacitate(meeting, capacity)

      _more ->
        {:ok, :skipped}
    end
  end

  defp insert_participant(meeting, capacity) do
    case ParticipantQueries.insert(participant_attrs(meeting)) do
      {:ok, participant} ->
        # Guests booked before the switch have no participant of their own, so
        # they count for nothing in seat maths until they are adopted.
        GuestQueries.adopt_unowned_guests(meeting.id, participant.id)
        snapshot_capacity(meeting, capacity)
        deliver_seat_management_link(meeting, participant)
        {:ok, :converted}

      {:error, changeset} ->
        # Left unconverted, this booking's attendee columns are still safe —
        # `Tymeslot.Meetings.Recipient.for_meeting/1` unions both shapes — so
        # it stays reachable by hand. What must not happen is this one row's
        # bad data (a pre-migration NULL, say) rolling back every other
        # booking converted alongside it in the same batch.
        Logger.error("Skipping unconvertible solo booking",
          meeting_id: meeting.id,
          errors: LogFormat.reason(changeset.errors)
        )

        {:ok, :skipped_poison}
    end
  end

  # The converted attendee has no management link of their own until this
  # runs — their old, pre-conversion cancel/reschedule link addresses the
  # whole meeting row, which `Tymeslot.Bookings.Cancel` and
  # `Tymeslot.Bookings.Reschedule` now both refuse for a group meeting. The
  # confirmation email is the existing per-seat job that carries the seat's
  # `management_token`-based links; it also re-notifies the organiser, which
  # is accepted here rather than adding a participant-only email path.
  # Never fails the conversion: an unreachable mailer is a follow-up, not a
  # reason to leave the booking unconverted.
  defp deliver_seat_management_link(meeting, participant) do
    case Orchestrator.schedule_seat_confirmation(meeting, participant) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule the converted seat's management link email",
          meeting_id: meeting.id,
          participant_id: participant.id,
          reason: LogFormat.reason(reason)
        )

        :ok
    end
  end

  defp recapacitate(%{capacity: capacity}, capacity), do: {:ok, :skipped}

  defp recapacitate(meeting, capacity) do
    snapshot_capacity(meeting, capacity)
    {:ok, :recapacitated}
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
          errors: LogFormat.reason(changeset.errors)
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
      timezone: attendee_timezone(meeting),
      locale: meeting.attendee_locale || "en",
      custom_field_answers: meeting.custom_field_answers || %{}
    }
  end

  # A handful of meetings booked before `attendee_timezone` existed
  # (migration `20250702181205`) carry no default and were never backfilled,
  # so the column is NULL on them. `ParticipantSchema` requires `:timezone`;
  # without a fallback these rows fail the changeset on every retry forever
  # (see `insert_participant/2`). The organiser's own timezone is the same
  # emergency fallback `Tymeslot.Notifications.Recipients.get_attendee_timezone/1`
  # already uses for notifications.
  defp attendee_timezone(%{attendee_timezone: timezone})
       when is_binary(timezone) and timezone != "",
       do: timezone

  defp attendee_timezone(meeting), do: Profiles.get_user_timezone(meeting.organizer_user_id)
end
