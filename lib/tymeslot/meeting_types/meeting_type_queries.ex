defmodule Tymeslot.MeetingTypes.MeetingTypeQueries do
  @moduledoc """
  Database queries for meeting types.
  """
  import Ecto.Query, warn: false
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Repo

  @doc """
  Gets all active meeting types for a user, ordered by sort_order.
  """
  @spec list_active_meeting_types(integer()) :: [MeetingTypeSchema.t()]
  def list_active_meeting_types(user_id) do
    query =
      from(mt in MeetingTypeSchema,
        where: mt.user_id == ^user_id and mt.is_active == true,
        order_by: [asc: mt.sort_order, asc: mt.name],
        preload: [:video_integration, :calendar_integration]
      )

    Repo.all(query)
  end

  @doc """
  Gets the publicly listed meeting types for a user (active and not private),
  ordered by sort_order. Private types are reachable only by their direct link,
  so they are excluded from the public overview this query feeds.
  """
  @spec list_public_meeting_types(integer()) :: [MeetingTypeSchema.t()]
  def list_public_meeting_types(user_id) do
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
  Gets a user's active, unarchived meeting type by its slug.

  Private types are included: a slug is not a listing, and a caller naming one
  is already trusted with the organiser's diary.
  """
  @spec get_active_by_slug(integer(), String.t()) ::
          {:ok, MeetingTypeSchema.t()} | {:error, :not_found}
  def get_active_by_slug(user_id, slug) when is_binary(slug) do
    query =
      from(mt in MeetingTypeSchema,
        where:
          mt.user_id == ^user_id and mt.slug == ^slug and mt.is_active == true and
            mt.is_archived == false,
        preload: [:video_integration, :calendar_integration]
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      meeting_type -> {:ok, meeting_type}
    end
  end

  @doc """
  Creates a new meeting type.

  `opts` are forwarded to `MeetingTypeSchema.changeset/3` so callers can
  thread payment-validation context (`:host_charges_enabled`,
  `:currency_minimum_cents`) into the changeset.
  """
  @spec create_meeting_type(map(), keyword()) ::
          {:ok, MeetingTypeSchema.t()} | {:error, Ecto.Changeset.t()}
  def create_meeting_type(attrs, opts \\ []) do
    %MeetingTypeSchema{}
    |> MeetingTypeSchema.changeset(attrs, opts)
    |> Repo.insert()
  end

  @doc """
  Updates a meeting type.

  `opts` are forwarded to `MeetingTypeSchema.changeset/3` (see
  `create_meeting_type/2`).
  """
  @spec update_meeting_type(MeetingTypeSchema.t(), map(), keyword()) ::
          {:ok, MeetingTypeSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_meeting_type(meeting_type, attrs, opts \\ []) do
    meeting_type
    |> MeetingTypeSchema.changeset(attrs, opts)
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
  Updates a meeting type's private visibility using a focused changeset.
  """
  @spec set_visibility(MeetingTypeSchema.t(), map()) ::
          {:ok, MeetingTypeSchema.t()} | {:error, Ecto.Changeset.t()}
  def set_visibility(meeting_type, attrs) do
    meeting_type
    |> MeetingTypeSchema.visibility_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates a meeting type's custom booking slug using a focused changeset.
  """
  @spec update_slug(MeetingTypeSchema.t(), map()) ::
          {:ok, MeetingTypeSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_slug(meeting_type, attrs) do
    meeting_type
    |> MeetingTypeSchema.slug_changeset(attrs)
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
  Resets `payment_required` and `price_cents` on every meeting type owned
  by the given user. Used when the host changes their Stripe Connect
  default currency — paid prices recorded in the old currency must not
  silently re-bill at the new one.
  """
  @spec clear_payments_for_user(integer()) :: {non_neg_integer(), nil}
  def clear_payments_for_user(user_id) when is_integer(user_id) do
    Repo.update_all(
      from(mt in MeetingTypeSchema, where: mt.user_id == ^user_id),
      set: [
        payment_required: false,
        price_cents: nil,
        updated_at: DateTime.utc_now(:second)
      ]
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
        updated_at: DateTime.utc_now(:second)
      ]
    )
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
  Checks if a user has at least one active meeting type.
  """
  @spec has_active_meeting_types?(integer()) :: boolean()
  def has_active_meeting_types?(user_id) do
    Repo.exists?(
      from(mt in MeetingTypeSchema,
        where: mt.user_id == ^user_id and mt.is_active == true
      )
    )
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
    now = DateTime.utc_now(:second)

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
end
