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

  @doc "Lists the guests for a meeting, oldest first."
  @spec list_for_meeting(binary()) :: [Guest.t()]
  def list_for_meeting(meeting_id) do
    Guest
    |> where([g], g.meeting_id == ^meeting_id)
    |> order_by([g], asc: g.inserted_at)
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
    |> order_by([g], asc: g.inserted_at)
    |> Repo.all()
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
