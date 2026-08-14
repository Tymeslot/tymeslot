defmodule Tymeslot.Availability.AvailabilityScheduleQueries do
  @moduledoc """
  Data access for `Tymeslot.Availability.AvailabilityScheduleSchema`.

  Queries and Repo calls only; the business rules around defaults, duplication
  and deletion live in `Tymeslot.Availability.Schedules`.
  """

  import Ecto.Query

  alias Tymeslot.Availability.AvailabilityScheduleSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Repo

  @doc """
  Lists a profile's schedules, default first, then alphabetically.
  """
  @spec list_by_profile(integer()) :: [AvailabilityScheduleSchema.t()]
  def list_by_profile(profile_id) do
    AvailabilityScheduleSchema
    |> where([s], s.profile_id == ^profile_id)
    |> order_by([s], desc: s.is_default, asc: s.name)
    |> Repo.all()
  end

  @doc """
  Counts a profile's schedules, used to enforce the per-profile cap.
  """
  @spec count_by_profile(integer()) :: non_neg_integer()
  def count_by_profile(profile_id) do
    AvailabilityScheduleSchema
    |> where([s], s.profile_id == ^profile_id)
    |> Repo.aggregate(:count)
  end

  @doc """
  Fetches a schedule by id.
  """
  @spec get(integer() | nil) :: AvailabilityScheduleSchema.t() | nil
  def get(nil), do: nil
  def get(id), do: Repo.get(AvailabilityScheduleSchema, id)

  @doc """
  Fetches a schedule by id, scoped to a profile so a caller cannot read another
  account's schedule by guessing an id.
  """
  @spec get_for_profile(integer(), integer()) :: AvailabilityScheduleSchema.t() | nil
  def get_for_profile(id, profile_id) do
    Repo.get_by(AvailabilityScheduleSchema, id: id, profile_id: profile_id)
  end

  @doc """
  Fetches a profile's default schedule.
  """
  @spec get_default(integer() | nil) :: AvailabilityScheduleSchema.t() | nil
  def get_default(nil), do: nil

  def get_default(profile_id) do
    Repo.get_by(AvailabilityScheduleSchema, profile_id: profile_id, is_default: true)
  end

  @doc """
  Inserts a schedule. Accepts an optional repo so callers already inside a
  transaction insert on the same connection.
  """
  @spec insert(map(), Ecto.Repo.t()) ::
          {:ok, AvailabilityScheduleSchema.t()} | {:error, Ecto.Changeset.t()}
  def insert(attrs, repo \\ Repo) do
    %AvailabilityScheduleSchema{}
    |> AvailabilityScheduleSchema.changeset(attrs)
    |> repo.insert()
  end

  @doc """
  Updates a schedule with the full changeset.
  """
  @spec update(AvailabilityScheduleSchema.t(), map()) ::
          {:ok, AvailabilityScheduleSchema.t()} | {:error, Ecto.Changeset.t()}
  def update(%AvailabilityScheduleSchema{} = schedule, attrs) do
    schedule
    |> AvailabilityScheduleSchema.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates only the three scheduling policy fields.
  """
  @spec update_policy(AvailabilityScheduleSchema.t(), map()) ::
          {:ok, AvailabilityScheduleSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_policy(%AvailabilityScheduleSchema{} = schedule, attrs) do
    schedule
    |> AvailabilityScheduleSchema.policy_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a schedule. Weekly rows, breaks and overrides cascade at the database
  level; meeting types referencing it are nilified by the foreign key.
  """
  @spec delete(AvailabilityScheduleSchema.t()) ::
          {:ok, AvailabilityScheduleSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete(%AvailabilityScheduleSchema{} = schedule), do: Repo.delete(schedule)

  @doc """
  Clears the default flag on every schedule of a profile.

  Called inside the `set_default` transaction before flagging the new default,
  so the partial unique index is never violated mid-transaction.
  """
  @spec clear_default(integer(), Ecto.Repo.t()) :: {non_neg_integer(), nil | [term()]}
  def clear_default(profile_id, repo \\ Repo) do
    AvailabilityScheduleSchema
    |> where([s], s.profile_id == ^profile_id and s.is_default == true)
    |> repo.update_all(set: [is_default: false])
  end

  @doc """
  Flags one schedule as the default. Used only inside the `set_default`
  transaction, after `clear_default/2`.
  """
  @spec mark_default(integer(), Ecto.Repo.t()) :: {non_neg_integer(), nil | [term()]}
  def mark_default(schedule_id, repo \\ Repo) do
    AvailabilityScheduleSchema
    |> where([s], s.id == ^schedule_id)
    |> repo.update_all(set: [is_default: true])
  end

  @doc """
  Names of the meeting types currently pointing at a schedule.

  Used by the delete confirmation so the user sees which meeting types fall back
  to the default.
  """
  @spec meeting_type_names(integer()) :: [String.t()]
  def meeting_type_names(schedule_id) do
    MeetingTypeSchema
    |> where([m], m.availability_schedule_id == ^schedule_id)
    |> order_by([m], asc: m.name)
    |> select([m], m.name)
    |> Repo.all()
  end
end
