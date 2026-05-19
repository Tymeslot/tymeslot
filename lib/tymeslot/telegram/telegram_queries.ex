defmodule Tymeslot.Telegram.TelegramQueries do
  @moduledoc """
  Database queries for Telegram integrations and deliveries.

  Shared CRUD operations across notification providers live in
  `Tymeslot.Notifications.IntegrationQueries`; this module owns Telegram-
  specific query logic (link-token lookup, status derivation post-processing,
  delivery stats) and delegates the rest.
  """

  import Ecto.Query, warn: false

  alias Tymeslot.Notifications.IntegrationQueries
  alias Tymeslot.Repo
  alias Tymeslot.Telegram.{TelegramDeliverySchema, TelegramIntegrationSchema}

  # ============================================================================
  # Integration Queries
  # ============================================================================

  @stub_ttl_minutes 30

  @spec list_integrations(integer()) :: [TelegramIntegrationSchema.t()]
  def list_integrations(user_id) do
    TelegramIntegrationSchema
    |> IntegrationQueries.list_for_user(user_id)
    |> Enum.map(&TelegramIntegrationSchema.derive_status/1)
  end

  @spec delete_pending_stubs(integer()) :: {non_neg_integer(), nil | [term()]}
  def delete_pending_stubs(user_id) do
    TelegramIntegrationSchema
    |> where([i], i.user_id == ^user_id)
    |> where([i], is_nil(i.chat_id))
    |> Repo.delete_all()
  end

  @spec cleanup_orphaned_stubs(integer()) :: {non_neg_integer(), nil | [term()]}
  def cleanup_orphaned_stubs(user_id) do
    TelegramIntegrationSchema
    |> where([i], i.user_id == ^user_id)
    |> where([i], is_nil(i.chat_id))
    |> IntegrationQueries.delete_stubs_older_than(@stub_ttl_minutes)
  end

  @spec list_active_integrations_for_event(integer(), String.t()) :: [
          TelegramIntegrationSchema.t()
        ]
  def list_active_integrations_for_event(user_id, event_type) do
    TelegramIntegrationSchema
    |> IntegrationQueries.list_active_for_event(user_id, event_type)
    |> Enum.filter(&(not is_nil(&1.chat_id)))
  end

  @spec find_by_link_token(String.t()) ::
          {:ok, TelegramIntegrationSchema.t()} | {:error, :not_found}
  def find_by_link_token(token) do
    result =
      TelegramIntegrationSchema
      |> where([i], i.link_token == ^token and is_nil(i.chat_id))
      |> Repo.one()

    case result do
      nil -> {:error, :not_found}
      integration -> {:ok, TelegramIntegrationSchema.derive_status(integration)}
    end
  end

  @spec get_integration(integer(), integer()) ::
          {:ok, TelegramIntegrationSchema.t()} | {:error, :not_found}
  def get_integration(id, user_id) do
    TelegramIntegrationSchema
    |> IntegrationQueries.get_for_user(id, user_id)
    |> maybe_derive_status()
  end

  @spec get_integration(integer()) :: {:ok, TelegramIntegrationSchema.t()} | {:error, :not_found}
  def get_integration(id) do
    TelegramIntegrationSchema
    |> IntegrationQueries.get(id)
    |> maybe_derive_status()
  end

  @spec create_integration(map()) ::
          {:ok, TelegramIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def create_integration(attrs) do
    %TelegramIntegrationSchema{}
    |> TelegramIntegrationSchema.changeset(attrs)
    |> IntegrationQueries.insert()
    |> maybe_derive_status()
  end

  @spec update_integration(TelegramIntegrationSchema.t(), map()) ::
          {:ok, TelegramIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_integration(%TelegramIntegrationSchema{} = integration, attrs) do
    integration
    |> TelegramIntegrationSchema.changeset(attrs)
    |> IntegrationQueries.update()
    |> maybe_derive_status()
  end

  @spec delete_integration(TelegramIntegrationSchema.t()) ::
          {:ok, TelegramIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete_integration(%TelegramIntegrationSchema{} = integration),
    do: IntegrationQueries.delete(integration)

  @spec toggle_integration(TelegramIntegrationSchema.t()) ::
          {:ok, TelegramIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def toggle_integration(%TelegramIntegrationSchema{} = integration) do
    TelegramIntegrationSchema
    |> IntegrationQueries.toggle_active(integration)
    |> maybe_derive_status()
  end

  @spec record_success(TelegramIntegrationSchema.t()) ::
          {:ok, TelegramIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def record_success(%TelegramIntegrationSchema{} = integration) do
    TelegramIntegrationSchema
    |> IntegrationQueries.record_success(integration)
    |> maybe_derive_status()
  end

  @spec increment_failure(TelegramIntegrationSchema.t()) ::
          {:ok, TelegramIntegrationSchema.t()} | {:error, :not_found}
  def increment_failure(%TelegramIntegrationSchema{id: id}) do
    TelegramIntegrationSchema
    |> IntegrationQueries.increment_failure(id)
    |> maybe_derive_status()
  end

  @spec enable_integration(TelegramIntegrationSchema.t()) ::
          {:ok, TelegramIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def enable_integration(%TelegramIntegrationSchema{} = integration) do
    TelegramIntegrationSchema
    |> IntegrationQueries.enable(integration)
    |> maybe_derive_status()
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
    IntegrationQueries.delivery_stats(TelegramDeliverySchema, integration_id, days_ago)
  end

  defp maybe_derive_status({:ok, integration}),
    do: {:ok, TelegramIntegrationSchema.derive_status(integration)}

  defp maybe_derive_status(error), do: error
end
