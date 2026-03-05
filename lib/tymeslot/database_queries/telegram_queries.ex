defmodule Tymeslot.DatabaseQueries.TelegramQueries do
  @moduledoc """
  Database queries for Telegram integrations and deliveries.
  """

  import Ecto.Query, warn: false

  alias Tymeslot.DatabaseSchemas.{TelegramDeliverySchema, TelegramIntegrationSchema}
  alias Tymeslot.Repo

  # ============================================================================
  # Integration Queries
  # ============================================================================

  @spec list_integrations(integer()) :: [TelegramIntegrationSchema.t()]
  def list_integrations(user_id) do
    TelegramIntegrationSchema
    |> where([i], i.user_id == ^user_id)
    |> order_by([i], desc: i.inserted_at)
    |> Repo.all()
    |> Enum.map(&TelegramIntegrationSchema.derive_status/1)
  end

  @spec list_active_integrations_for_event(integer(), String.t()) :: [TelegramIntegrationSchema.t()]
  def list_active_integrations_for_event(user_id, event_type) do
    TelegramIntegrationSchema
    |> where([i], i.user_id == ^user_id)
    |> where([i], i.is_active == true)
    |> where([i], is_nil(i.disabled_at))
    |> where([i], not is_nil(i.chat_id))
    |> where([i], fragment("? = ANY(?)", ^event_type, i.events))
    |> Repo.all()
  end

  @spec get_integration(integer(), integer()) ::
          {:ok, TelegramIntegrationSchema.t()} | {:error, :not_found}
  def get_integration(id, user_id) do
    case Repo.get_by(TelegramIntegrationSchema, id: id, user_id: user_id) do
      nil -> {:error, :not_found}
      integration -> {:ok, TelegramIntegrationSchema.derive_status(integration)}
    end
  end

  @spec get_integration(integer()) :: {:ok, TelegramIntegrationSchema.t()} | {:error, :not_found}
  def get_integration(id) do
    case Repo.get(TelegramIntegrationSchema, id) do
      nil -> {:error, :not_found}
      integration -> {:ok, TelegramIntegrationSchema.derive_status(integration)}
    end
  end

  @spec create_integration(map()) ::
          {:ok, TelegramIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def create_integration(attrs) do
    %TelegramIntegrationSchema{}
    |> TelegramIntegrationSchema.changeset(attrs)
    |> Repo.insert()
    |> maybe_derive_status()
  end

  @spec update_integration(TelegramIntegrationSchema.t(), map()) ::
          {:ok, TelegramIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_integration(%TelegramIntegrationSchema{} = integration, attrs) do
    integration
    |> TelegramIntegrationSchema.changeset(attrs)
    |> Repo.update()
    |> maybe_derive_status()
  end

  @spec delete_integration(TelegramIntegrationSchema.t()) ::
          {:ok, TelegramIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete_integration(%TelegramIntegrationSchema{} = integration) do
    Repo.delete(integration)
  end

  @spec toggle_integration(TelegramIntegrationSchema.t()) ::
          {:ok, TelegramIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def toggle_integration(%TelegramIntegrationSchema{} = integration) do
    update_integration(integration, %{is_active: !integration.is_active})
  end

  @spec record_success(TelegramIntegrationSchema.t()) ::
          {:ok, TelegramIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def record_success(%TelegramIntegrationSchema{} = integration) do
    update_integration(integration, %{
      last_triggered_at: DateTime.utc_now(),
      failure_count: 0
    })
  end

  @spec record_failure(TelegramIntegrationSchema.t(), String.t()) ::
          {:ok, TelegramIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def record_failure(%TelegramIntegrationSchema{id: id}, reason) do
    {1, [updated]} =
      TelegramIntegrationSchema
      |> where([i], i.id == ^id)
      |> select([i], i)
      |> Repo.update_all(inc: [failure_count: 1])

    if updated.failure_count >= 10 do
      update_integration(updated, %{
        is_active: false,
        disabled_at: DateTime.utc_now(),
        disabled_reason: "Too many consecutive failures: #{reason}"
      })
    else
      {:ok, TelegramIntegrationSchema.derive_status(updated)}
    end
  end

  @spec enable_integration(TelegramIntegrationSchema.t()) ::
          {:ok, TelegramIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def enable_integration(%TelegramIntegrationSchema{} = integration) do
    update_integration(integration, %{
      is_active: true,
      disabled_at: nil,
      disabled_reason: nil,
      failure_count: 0
    })
  end

  # ============================================================================
  # Delivery Queries
  # ============================================================================

  @spec list_deliveries(integer(), keyword()) :: [TelegramDeliverySchema.t()]
  def list_deliveries(integration_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    TelegramDeliverySchema
    |> where([d], d.integration_id == ^integration_id)
    |> order_by([d], desc: d.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @spec create_delivery(map()) ::
          {:ok, TelegramDeliverySchema.t()} | {:error, Ecto.Changeset.t()}
  def create_delivery(attrs) do
    %TelegramDeliverySchema{}
    |> TelegramDeliverySchema.changeset(attrs)
    |> Repo.insert()
  end

  @spec get_delivery_stats(integer(), keyword()) :: map()
  def get_delivery_stats(integration_id, opts \\ []) do
    days_ago = Keyword.get(opts, :days, 7)
    since = DateTime.add(DateTime.utc_now(), -days_ago, :day)

    query =
      from d in TelegramDeliverySchema,
        where: d.integration_id == ^integration_id and d.inserted_at >= ^since

    total = Repo.aggregate(query, :count, :id)

    successful =
      query
      |> where([d], d.response_status >= 200 and d.response_status < 300)
      |> Repo.aggregate(:count, :id)

    failed =
      query
      |> where([d], d.response_status >= 400 or not is_nil(d.error_message))
      |> Repo.aggregate(:count, :id)

    %{
      total: total,
      successful: successful,
      failed: failed,
      success_rate: if(total > 0, do: Float.round(successful / total * 100, 1), else: 0.0),
      period_days: days_ago
    }
  end

  defp maybe_derive_status({:ok, integration}),
    do: {:ok, TelegramIntegrationSchema.derive_status(integration)}

  defp maybe_derive_status(error), do: error
end
