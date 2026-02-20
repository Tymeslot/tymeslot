defmodule Tymeslot.DatabaseQueries.IntegrationHealthStateQueries do
  @moduledoc """
  Database queries for integration health state persistence.

  Provides get/upsert operations for the `integration_health_states` table,
  which stores the current health monitoring state for each calendar and video
  integration so that state survives process restarts.
  """

  import Ecto.Query

  alias Tymeslot.DatabaseSchemas.IntegrationHealthStateSchema
  alias Tymeslot.Repo

  @doc """
  Retrieves the health state record for a specific integration.
  Returns `{:ok, record}` or `{:error, :not_found}`.
  """
  @spec get(String.t() | atom(), integer()) ::
          {:ok, IntegrationHealthStateSchema.t()} | {:error, :not_found}
  def get(type, integration_id) do
    type_str = to_string(type)

    case Repo.get_by(IntegrationHealthStateSchema,
           integration_type: type_str,
           integration_id: integration_id
         ) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  @doc """
  Retrieves or initialises the health state record for an integration.

  If no record exists, inserts a default healthy state using `on_conflict: :nothing`
  and returns the (possibly just-created) record.
  """
  @spec get_or_init(String.t() | atom(), integer(), integer()) ::
          {:ok, IntegrationHealthStateSchema.t()} | {:error, :not_found}
  def get_or_init(type, integration_id, user_id) do
    type_str = to_string(type)

    seed_attrs = %{
      integration_type: type_str,
      integration_id: integration_id,
      user_id: user_id,
      status: "healthy",
      failures: 0,
      successes: 0,
      backoff_ms: 1_800_000
    }

    %IntegrationHealthStateSchema{}
    |> IntegrationHealthStateSchema.changeset(seed_attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:integration_type, :integration_id])

    case Repo.get_by(IntegrationHealthStateSchema,
           integration_type: type_str,
           integration_id: integration_id
         ) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  @doc """
  Upserts the health state for an integration.

  Replaces all provided fields on conflict against the `[integration_type, integration_id]`
  unique index. Returns `{:ok, record}` on success.
  """
  @spec upsert(String.t() | atom(), integer(), map()) ::
          {:ok, IntegrationHealthStateSchema.t()} | {:error, any()}
  def upsert(type, integration_id, attrs) do
    type_str = to_string(type)
    replace_fields = Map.keys(attrs) ++ [:updated_at]

    attrs_with_identity =
      attrs
      |> Map.put(:integration_type, type_str)
      |> Map.put(:integration_id, integration_id)

    %IntegrationHealthStateSchema{}
    |> IntegrationHealthStateSchema.upsert_changeset(attrs_with_identity)
    |> Repo.insert(
      on_conflict: {:replace, replace_fields},
      conflict_target: [:integration_type, :integration_id],
      returning: true
    )
  end

  @doc """
  Updates specific fields on an existing health state record.
  Only updates if a record already exists (no INSERT). Safe to call concurrently.
  Returns the number of records updated (0 if no record exists).
  """
  @spec update_fields(String.t() | atom(), integer(), keyword()) :: {non_neg_integer(), nil}
  def update_fields(type, integration_id, field_updates) do
    type_str = to_string(type)

    Repo.update_all(
      from(s in IntegrationHealthStateSchema,
        where: s.integration_type == ^type_str and s.integration_id == ^integration_id
      ),
      set: field_updates ++ [updated_at: DateTime.utc_now()]
    )
  end

  @doc """
  Returns all unhealthy integration health state records for a user.
  Used to populate in-app health badges on integration cards.
  """
  @spec list_unhealthy_for_user(integer()) :: [IntegrationHealthStateSchema.t()]
  def list_unhealthy_for_user(user_id) do
    IntegrationHealthStateSchema
    |> where([s], s.user_id == ^user_id and s.status == "unhealthy")
    |> Repo.all()
  end
end
