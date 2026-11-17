defmodule Tymeslot.BookingSeries.SeriesQueries do
  @moduledoc """
  Data access for `booking_series`. Every `Repo` call on a series lives here.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.BookingSeries.SeriesSchema, as: Series
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.ParticipantSchema, as: Participant
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Repo

  @doc "Inserts a series."
  @spec insert(map()) :: {:ok, Series.t()} | {:error, Changeset.t()}
  def insert(attrs) when is_map(attrs) do
    attrs
    |> Series.create_changeset()
    |> Repo.insert()
  end

  @doc """
  Fetches a series by id, unscoped: for system callers (the series' email
  jobs), never for a request.
  """
  @spec get(binary()) :: {:ok, Series.t()} | {:error, :not_found}
  def get(id) do
    with {:ok, id} <- UUID.cast(id),
         %Series{} = series <- Repo.get(Series, id) do
      {:ok, series}
    else
      :error -> {:error, :not_found}
      nil -> {:error, :not_found}
    end
  end

  @doc "Fetches a series by its bearer `uid`."
  @spec get_by_uid(String.t()) :: {:ok, Series.t()} | {:error, :not_found}
  def get_by_uid(uid) when is_binary(uid) do
    with {:ok, uid} <- UUID.cast(uid),
         %Series{} = series <- Repo.get_by(Series, uid: uid) do
      {:ok, series}
    else
      :error -> {:error, :not_found}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  The username the organiser of the series with bearer `uid` has now, if
  any and not pending deletion.
  """
  @spec organizer_username_by_uid(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def organizer_username_by_uid(uid) when is_binary(uid) do
    with {:ok, uid} <- UUID.cast(uid),
         username when is_binary(username) <- Repo.one(organizer_username_query(uid)) do
      {:ok, username}
    else
      _unknown -> {:error, :not_found}
    end
  end

  defp organizer_username_query(uid) do
    from(s in Series,
      join: p in ProfileSchema,
      on: p.user_id == s.organizer_user_id,
      join: u in assoc(p, :user),
      where: s.uid == ^uid and p.username != "" and is_nil(u.deletion_scheduled_at),
      select: p.username
    )
  end

  @doc "Fetches a series by id, scoped to the organiser that owns it."
  @spec get_for_organizer(binary(), integer()) :: {:ok, Series.t()} | {:error, :not_found}
  def get_for_organizer(id, organizer_user_id) do
    with {:ok, id} <- UUID.cast(id),
         %Series{} = series <-
           Repo.get_by(Series, id: id, organizer_user_id: organizer_user_id) do
      {:ok, series}
    else
      :error -> {:error, :not_found}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Re-reads the series with `FOR UPDATE`. Call inside a transaction to
  serialise changes to one series.
  """
  @spec lock(Series.t() | binary()) :: Series.t() | nil
  def lock(%Series{id: id}), do: lock(id)

  def lock(id) when is_binary(id) do
    Series
    |> where([s], s.id == ^id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  @doc "Stamps `cancelled_at` on the series: nothing of it is left to come."
  @spec mark_cancelled(Series.t(), DateTime.t()) :: {:ok, Series.t()} | {:error, Changeset.t()}
  def mark_cancelled(%Series{} = series, %DateTime{} = cancelled_at) do
    series
    |> Series.cancel_changeset(cancelled_at)
    |> Repo.update()
  end

  @doc "The meetings of a one-to-one series, in `series_position` order."
  @spec list_meetings(Series.t() | binary()) :: [Meeting.t()]
  def list_meetings(%Series{id: id}), do: list_meetings(id)

  def list_meetings(id) when is_binary(id) do
    Meeting
    |> where([m], m.series_id == ^id)
    |> order_by([m], asc: m.series_position)
    |> Repo.all()
  end

  @doc "A query for a series' meetings in `series_position` order, to preload them by."
  @spec ordered_meetings() :: Ecto.Query.t()
  def ordered_meetings, do: from(m in Meeting, order_by: [asc: m.series_position])

  @doc """
  Locks the meetings of a one-to-one series with `FOR UPDATE`, in
  `series_position` order, and returns them in that order. Every writer
  that locks several sessions takes them in this order, after the series
  row, so two cannot deadlock. Call inside a transaction.
  """
  @spec lock_meetings(Series.t() | binary()) :: [Meeting.t()]
  def lock_meetings(%Series{id: id}), do: lock_meetings(id)

  def lock_meetings(id) when is_binary(id) do
    Meeting
    |> where([m], m.series_id == ^id)
    |> order_by([m], asc: m.series_position)
    |> lock("FOR UPDATE")
    |> Repo.all()
  end

  @doc """
  When the series' first session started as booked (`first_start_at`),
  however its sessions have moved since. Nil for an unknown series, or one
  booked with no first start recorded.
  """
  @spec first_start(binary()) :: DateTime.t() | nil
  def first_start(id) when is_binary(id) do
    Repo.one(from(s in Series, where: s.id == ^id, select: s.first_start_at))
  end

  @doc """
  Lists the occurrences of a series by `series_position`: `Meeting` structs
  for one-to-one types, `Participant` structs (meeting preloaded) for group
  types.

  A seat moved to another session is cancelled and replaced by a new seat
  in the same position (`Tymeslot.Bookings.RescheduleSeat`), so a position
  can hold several seats; it is listed once, as its current seat: the live
  one, or, with none live, the one cancelled last. A one-to-one session
  moves in place and is never doubled.
  """
  @spec list_occurrences(Series.t() | binary()) :: [Meeting.t() | Participant.t()]
  def list_occurrences(%Series{id: id}), do: list_occurrences(id)

  def list_occurrences(id) when is_binary(id) do
    meetings = Meeting |> where([m], m.series_id == ^id) |> Repo.all()

    seats =
      Participant
      |> where([p], p.series_id == ^id)
      |> preload(:meeting)
      |> Repo.all()
      |> Enum.group_by(& &1.series_position)
      |> Enum.map(fn {_position, seats} -> current_seat(seats) end)

    Enum.sort_by(meetings ++ seats, & &1.series_position)
  end

  defp current_seat(seats) do
    Enum.find(seats, &is_nil(&1.cancelled_at)) ||
      Enum.max_by(seats, &{DateTime.to_unix(&1.cancelled_at), DateTime.to_unix(&1.inserted_at)})
  end
end
