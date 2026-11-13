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

  @doc """
  Lists the occurrences of a series by `series_position`: `Meeting` structs
  for one-to-one types, `Participant` structs (meeting preloaded) for group
  types.
  """
  @spec list_occurrences(Series.t() | binary()) :: [Meeting.t() | Participant.t()]
  def list_occurrences(%Series{id: id}), do: list_occurrences(id)

  def list_occurrences(id) when is_binary(id) do
    meetings = Meeting |> where([m], m.series_id == ^id) |> Repo.all()

    participants =
      Participant
      |> where([p], p.series_id == ^id)
      |> preload(:meeting)
      |> Repo.all()

    Enum.sort_by(meetings ++ participants, & &1.series_position)
  end
end
