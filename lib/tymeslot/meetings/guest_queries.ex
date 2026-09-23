defmodule Tymeslot.Meetings.GuestQueries do
  @moduledoc """
  Database queries for the `meeting_guests` table.

  Pure data access only — business rules (sanitising guest lists, deciding when
  an RSVP is allowed) live in `Tymeslot.Meetings.Guests`.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Tymeslot.Meetings.GuestSchema, as: Guest
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Repo

  @doc "Inserts a single guest for a meeting."
  @spec insert_guest(map()) :: {:ok, Guest.t()} | {:error, Changeset.t()}
  def insert_guest(attrs) when is_map(attrs) do
    %Guest{}
    |> Guest.creation_changeset(attrs)
    |> Repo.insert()
  end

  @doc "Fetches a guest by its RSVP token."
  @spec get_by_token(String.t()) :: {:ok, Guest.t()} | {:error, :not_found}
  def get_by_token(token) when is_binary(token) do
    case Repo.get_by(Guest, rsvp_token: token) do
      nil -> {:error, :not_found}
      guest -> {:ok, guest}
    end
  end

  # `inserted_at` is second-precision, and a booking's guests are all inserted
  # inside the same second, so ordering on it alone is not a total order and
  # Postgres may hand the rows back either way round. Email breaks the tie:
  # it is unique per meeting, so the order is stable across calls.
  @doc "Lists the guests for a meeting, oldest first."
  @spec list_for_meeting(binary()) :: [Guest.t()]
  def list_for_meeting(meeting_id) do
    Guest
    |> where([g], g.meeting_id == ^meeting_id)
    |> order_by([g], asc: g.inserted_at, asc: g.email)
    |> Repo.all()
  end

  @doc "Applies an RSVP changeset and persists the guest."
  @spec update_rsvp(Guest.t(), map()) :: {:ok, Guest.t()} | {:error, Changeset.t()}
  def update_rsvp(%Guest{} = guest, attrs) when is_map(attrs) do
    guest
    |> Guest.rsvp_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Lists the guests for a meeting whose confirmation email has not yet been sent.
  """
  @spec list_unsent_for_meeting(binary()) :: [Guest.t()]
  def list_unsent_for_meeting(meeting_id) do
    Guest
    |> where([g], g.meeting_id == ^meeting_id and is_nil(g.confirmation_sent_at))
    |> order_by([g], asc: g.inserted_at, asc: g.email)
    |> Repo.all()
  end

  @doc """
  Clears everything a meeting's guests were told about, or answered for, its
  previous time: their RSVPs, and the reminder offsets already emailed.

  The mirror of the `reminders_sent`/`reminder_email_sent` reset
  `Tymeslot.Bookings.Reschedule` performs on the meeting row itself. Left
  behind, a guest already reminded for an offset is rejected by
  `list_for_reminder/3` at the new time and silently never reminded again,
  while the host and the booker are.
  """
  @spec reset_for_new_time(binary()) :: non_neg_integer()
  def reset_for_new_time(meeting_id) do
    {count, _rows} =
      Guest
      |> where([g], g.meeting_id == ^meeting_id)
      |> Repo.update_all(
        set: [
          status: "pending",
          responded_at: nil,
          reminders_sent: nil,
          updated_at: DateTime.utc_now(:second)
        ]
      )

    count
  end

  @doc "Stamps `confirmation_sent_at` on the given guest."
  @spec mark_confirmation_sent(Guest.t(), DateTime.t()) ::
          {:ok, Guest.t()} | {:error, Changeset.t()}
  def mark_confirmation_sent(%Guest{} = guest, sent_at) do
    guest
    |> Guest.confirmation_sent_changeset(sent_at)
    |> Repo.update()
  end

  @doc """
  Guests to send the reminder for one configured offset to.

  Excludes guests who were never invited (no confirmation), guests who have
  declined (the time has not changed, so their answer still stands), and
  guests already stamped for this very offset. The last is what makes an Oban
  retry safe: a meeting is reminded once per configured offset, so a partial
  send must not re-email the guests it already reached.
  """
  @spec list_for_reminder(binary(), integer(), String.t()) :: [Guest.t()]
  def list_for_reminder(meeting_id, value, unit) do
    Guest
    |> where([g], g.meeting_id == ^meeting_id)
    |> where([g], not is_nil(g.confirmation_sent_at))
    |> where([g], g.status != "declined")
    |> order_by([g], asc: g.inserted_at, asc: g.email)
    |> Repo.all()
    |> Enum.reject(&reminder_sent?(&1, value, unit))
  end

  @doc """
  Records that this guest has been emailed the reminder for one offset,
  preserving the offsets already recorded.
  """
  @spec mark_reminder_sent(Guest.t(), integer(), String.t()) ::
          {:ok, Guest.t()} | {:error, Changeset.t()}
  def mark_reminder_sent(%Guest{} = guest, value, unit) do
    if reminder_sent?(guest, value, unit) do
      {:ok, guest}
    else
      entry = %{"value" => value, "unit" => unit}

      guest
      |> Guest.reminders_sent_changeset(List.wrap(guest.reminders_sent) ++ [entry])
      |> Repo.update()
    end
  end

  # Entries are written as string-keyed maps and read back from jsonb the same
  # way, but a struct built in memory can still carry atom keys.
  defp reminder_sent?(%Guest{reminders_sent: reminders_sent}, value, unit) do
    reminders_sent
    |> List.wrap()
    |> Enum.any?(fn
      %{"value" => v, "unit" => u} -> v == value and u == unit
      %{value: v, unit: u} -> v == value and u == unit
      _other -> false
    end)
  end

  @doc """
  Returns a map of `meeting_uid => RSVP summary` for every meeting the given
  user organises that has at least one guest. One grouped query for the whole
  dashboard, keyed by `uid` so both the bookings list and the calendar grid
  (whose events carry the meeting `uid`) can look up a summary directly.
  """
  @spec rsvp_summaries_for_user(integer()) :: %{String.t() => Guest.summary()}
  def rsvp_summaries_for_user(user_id) do
    query =
      from(g in Guest,
        join: m in Meeting,
        on: m.id == g.meeting_id,
        where: m.organizer_user_id == ^user_id,
        group_by: [m.uid, g.status],
        select: {m.uid, g.status, count(g.id)}
      )

    query
    |> Repo.all()
    |> Enum.reduce(%{}, fn {uid, status, count}, acc ->
      summary = Map.get(acc, uid, Guest.empty_summary())

      summary =
        summary
        |> Map.update!(:total, &(&1 + count))
        |> Map.update!(Guest.status_key(status), &(&1 + count))

      Map.put(acc, uid, summary)
    end)
  end
end
