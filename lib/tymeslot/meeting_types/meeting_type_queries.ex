defmodule Tymeslot.MeetingTypes.MeetingTypeQueries do
  @moduledoc """
  Database queries for meeting types.
  """
  import Ecto.Query, warn: false
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Repo

  @doc """
  Gets all active meeting types for a user, ordered by sort_order.
  Excludes private meeting types (is_private: true) — those are only accessible via token links.
  """
  @spec list_active_meeting_types(integer()) :: [MeetingTypeSchema.t()]
  def list_active_meeting_types(user_id) do
    query =
      from(mt in MeetingTypeSchema,
        where: mt.user_id == ^user_id and mt.is_active == true and mt.is_private == false,
        order_by: [asc: mt.sort_order, asc: mt.name],
        preload: [:video_integration, :calendar_integration]
      )

    Repo.all(query)
  end

  @doc """
  Gets all meeting types for a user (active and inactive), ordered by sort_order.
  """
  @spec list_all_meeting_types(integer()) :: [MeetingTypeSchema.t()]
  def list_all_meeting_types(user_id) do
    query =
      from(mt in MeetingTypeSchema,
        where: mt.user_id == ^user_id,
        order_by: [asc: mt.sort_order, asc: mt.name],
        preload: [:video_integration, :calendar_integration]
      )

    Repo.all(query)
  end

  @doc """
  Gets a meeting type by ID and user ID.
  """
  @spec get_meeting_type(integer(), integer()) :: MeetingTypeSchema.t() | nil
  def get_meeting_type(id, user_id) do
    query =
      from(mt in MeetingTypeSchema,
        where: mt.id == ^id and mt.user_id == ^user_id,
        preload: [:video_integration, :calendar_integration]
      )

    Repo.one(query)
  end

  @doc """
  Tagged-tuple variant of get_meeting_type/2.
  Returns {:ok, meeting_type} or {:error, :not_found}.
  """
  @spec get_meeting_type_t(integer(), integer()) ::
          {:ok, MeetingTypeSchema.t()} | {:error, :not_found}
  def get_meeting_type_t(id, user_id) do
    case get_meeting_type(id, user_id) do
      nil -> {:error, :not_found}
      mt -> {:ok, mt}
    end
  end

  @doc """
  Creates a new meeting type.
  """
  @spec create_meeting_type(map()) :: {:ok, MeetingTypeSchema.t()} | {:error, Ecto.Changeset.t()}
  def create_meeting_type(attrs) do
    %MeetingTypeSchema{}
    |> MeetingTypeSchema.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a meeting type.
  """
  @spec update_meeting_type(MeetingTypeSchema.t(), map()) ::
          {:ok, MeetingTypeSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_meeting_type(meeting_type, attrs) do
    meeting_type
    |> MeetingTypeSchema.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Toggles the active status of a meeting type.
  Uses a simplified changeset that doesn't validate video integration requirements.
  """
  @spec toggle_meeting_type_status(MeetingTypeSchema.t(), map()) ::
          {:ok, MeetingTypeSchema.t()} | {:error, Ecto.Changeset.t()}
  def toggle_meeting_type_status(meeting_type, attrs) do
    meeting_type
    |> MeetingTypeSchema.toggle_active_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a meeting type.
  """
  @spec delete_meeting_type(MeetingTypeSchema.t()) ::
          {:ok, MeetingTypeSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete_meeting_type(meeting_type) do
    Repo.delete(meeting_type)
  end

  @doc """
  Bulk-inserts meeting types from a list of attribute maps.
  Each map must include all required fields including timestamps.
  Returns `{:ok, meeting_types}` on success.
  """
  @spec bulk_insert_meeting_types([map()]) :: {:ok, [MeetingTypeSchema.t()]} | {:error, term()}
  def bulk_insert_meeting_types([]), do: {:ok, []}

  def bulk_insert_meeting_types(attrs_list) when is_list(attrs_list) do
    case Repo.insert_all(MeetingTypeSchema, attrs_list, returning: true) do
      {_count, meeting_types} ->
        {:ok, meeting_types}
    end
  rescue
    error -> {:error, error}
  end

  @doc """
  Returns the names of all existing meeting types for a user as a MapSet.
  """
  @spec existing_names(integer()) :: MapSet.t()
  def existing_names(user_id) do
    MapSet.new(
      Repo.all(
        from(mt in MeetingTypeSchema,
          where: mt.user_id == ^user_id,
          select: mt.name
        )
      )
    )
  end

  @doc """
  Clears calendar references (`calendar_integration_id` and `target_calendar_id`)
  on all meeting types pointing to the given calendar integration.

  Called before deleting a calendar integration to prevent stale `target_calendar_id`
  values (which is a plain string, not a FK, and would survive cascade).
  """
  @spec clear_calendar_references(integer()) :: {non_neg_integer(), nil}
  def clear_calendar_references(calendar_integration_id)
      when is_integer(calendar_integration_id) do
    Repo.update_all(
      from(mt in MeetingTypeSchema,
        where: mt.calendar_integration_id == ^calendar_integration_id
      ),
      set: [
        calendar_integration_id: nil,
        target_calendar_id: nil,
        updated_at: NaiveDateTime.utc_now(:second)
      ]
    )
  end

  @doc """
  Legacy function for individual meeting type creation.
  Consider using bulk operations for better performance when creating multiple types.
  Only creates types that don't already exist for the user.
  """
  @spec create_default_meeting_types_individual(integer()) ::
          {:ok, [MeetingTypeSchema.t()]} | {:error, term()}
  def create_default_meeting_types_individual(user_id) when is_integer(user_id) do
    existing = existing_names(user_id)

    default_types =
      Enum.reject(
        [
          %{
            user_id: user_id,
            name: "15 Minutes",
            description: "Quick chat or brief consultation",
            duration_minutes: 15,
            icon: "hero-bolt",
            sort_order: 0,
            allow_video: false,
            reminder_config: [%{value: 30, unit: "minutes"}]
          },
          %{
            user_id: user_id,
            name: "30 Minutes",
            description: "In-depth discussion or detailed review",
            duration_minutes: 30,
            icon: "hero-rocket-launch",
            sort_order: 1,
            allow_video: false,
            reminder_config: [%{value: 30, unit: "minutes"}]
          }
        ],
        fn type -> MapSet.member?(existing, type.name) end
      )

    handle_individual_defaults_creation(default_types)
  end

  @spec create_default_meeting_types_individual(term()) :: {:error, :invalid_user_id}
  def create_default_meeting_types_individual(_invalid_user_id) do
    {:error, :invalid_user_id}
  end

  @doc """
  Checks if a user has any meeting types.
  """
  @spec has_meeting_types?(integer()) :: boolean()
  def has_meeting_types?(user_id) do
    result =
      Repo.one(
        from(mt in MeetingTypeSchema,
          where: mt.user_id == ^user_id,
          select: count(mt.id)
        )
      )

    case result do
      0 -> false
      _other -> true
    end
  end

  @doc """
  Counts meeting types for a user.
  """
  @spec count_for_user(integer()) :: non_neg_integer()
  def count_for_user(user_id) do
    query =
      from(mt in MeetingTypeSchema,
        where: mt.user_id == ^user_id,
        select: count(mt.id)
      )

    Repo.one(query) || 0
  end

  @doc """
  Gets a meeting type by ID, raising if not found.
  """
  @spec get_meeting_type!(integer()) :: MeetingTypeSchema.t()
  def get_meeting_type!(id) do
    Repo.get!(MeetingTypeSchema, id)
  end

  @doc """
  Updates all meeting types for a user with new sort orders.
  """
  @spec reorder_meeting_types(integer(), [integer()]) :: {:ok, any()} | {:error, any()}
  def reorder_meeting_types(user_id, meeting_type_ids) when is_list(meeting_type_ids) do
    now = NaiveDateTime.utc_now(:second)

    Repo.transaction(fn ->
      results =
        Enum.with_index(meeting_type_ids, fn meeting_type_id, index ->
          MeetingTypeSchema
          |> where([mt], mt.id == ^meeting_type_id and mt.user_id == ^user_id)
          |> Repo.update_all(set: [sort_order: index, updated_at: now])
        end)

      total_updated = Enum.sum(Enum.map(results, fn {count, _nil} -> count end))

      if total_updated != length(meeting_type_ids) do
        Repo.rollback(:partial_reorder)
      else
        results
      end
    end)
  end

  defp handle_individual_defaults_creation([]), do: {:ok, []}

  defp handle_individual_defaults_creation(types_to_create) when is_list(types_to_create) do
    results = Enum.map(types_to_create, &create_meeting_type/1)

    case Enum.find(results, fn {status, _value} -> status != :ok end) do
      nil -> {:ok, Enum.map(results, fn {:ok, mt} -> mt end)}
      _other -> {:error, :bulk_creation_failed}
    end
  end
end
