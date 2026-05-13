defmodule Tymeslot.Slack.SlackQueries do
  @moduledoc """
  Database queries for Slack integrations and deliveries.

  Shared CRUD operations across notification providers live in
  `Tymeslot.Notifications.IntegrationQueries`; this module owns Slack-specific
  query logic (OAuth-pending stub cleanup, status post-filtering, delivery
  stats) and delegates the rest.
  """

  import Ecto.Query, warn: false

  alias Tymeslot.Notifications.IntegrationQueries
  alias Tymeslot.Repo
  alias Tymeslot.Slack.{SlackDeliverySchema, SlackIntegrationSchema}

  # ============================================================================
  # Integration Queries
  # ============================================================================

  @stub_ttl_minutes 30

  @spec list_integrations(integer()) :: [SlackIntegrationSchema.t()]
  def list_integrations(user_id),
    do: IntegrationQueries.list_for_user(SlackIntegrationSchema, user_id)

  @doc """
  Deletes every OAuth-mode integration for the user that has not yet had its
  channel picked — covers both freshly-initialised stubs and abandoned OAuth
  installs from previous attempts. Run before inserting a new stub so the user
  does not accumulate orphaned `:pending_oauth` rows.
  """
  @spec delete_pending_stubs(integer()) :: {non_neg_integer(), nil | [term()]}
  def delete_pending_stubs(user_id) do
    SlackIntegrationSchema
    |> where([i], i.user_id == ^user_id)
    |> where([i], i.app_mode == "oauth")
    |> where([i], is_nil(i.channel_id))
    |> Repo.delete_all()
  end

  @spec cleanup_orphaned_stubs(integer()) :: {non_neg_integer(), nil | [term()]}
  def cleanup_orphaned_stubs(user_id) do
    SlackIntegrationSchema
    |> where([i], i.user_id == ^user_id)
    |> where([i], i.app_mode == "oauth")
    |> where([i], is_nil(i.channel_id))
    |> IntegrationQueries.delete_stubs_older_than(@stub_ttl_minutes)
  end

  @spec list_active_integrations_for_event(integer(), String.t()) :: [
          SlackIntegrationSchema.t()
        ]
  def list_active_integrations_for_event(user_id, event_type) do
    SlackIntegrationSchema
    |> IntegrationQueries.list_active_for_event(user_id, event_type)
    |> Enum.filter(&active_status?/1)
  end

  @spec find_by_link_token(String.t()) ::
          {:ok, SlackIntegrationSchema.t()} | {:error, :not_found}
  def find_by_link_token(token) do
    result =
      SlackIntegrationSchema
      |> where([i], i.link_token == ^token)
      |> Repo.one()

    case result do
      nil -> {:error, :not_found}
      integration -> {:ok, integration}
    end
  end

  @spec get_integration(integer(), integer()) ::
          {:ok, SlackIntegrationSchema.t()} | {:error, :not_found}
  def get_integration(id, user_id),
    do: IntegrationQueries.get_for_user(SlackIntegrationSchema, id, user_id)

  @spec get_integration(integer()) ::
          {:ok, SlackIntegrationSchema.t()} | {:error, :not_found}
  def get_integration(id), do: IntegrationQueries.get(SlackIntegrationSchema, id)

  @spec create_integration(map()) ::
          {:ok, SlackIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def create_integration(attrs) do
    %SlackIntegrationSchema{}
    |> SlackIntegrationSchema.changeset(attrs)
    |> IntegrationQueries.insert()
  end

  @spec create_oauth_stub(map()) ::
          {:ok, SlackIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def create_oauth_stub(attrs) do
    %SlackIntegrationSchema{}
    |> SlackIntegrationSchema.oauth_init_changeset(attrs)
    |> IntegrationQueries.insert()
  end

  @spec update_integration(SlackIntegrationSchema.t(), map()) ::
          {:ok, SlackIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_integration(%SlackIntegrationSchema{} = integration, attrs) do
    integration
    |> SlackIntegrationSchema.changeset(attrs)
    |> IntegrationQueries.update()
  end

  @spec set_channel(SlackIntegrationSchema.t(), map()) ::
          {:ok, SlackIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def set_channel(%SlackIntegrationSchema{} = integration, attrs) do
    integration
    |> SlackIntegrationSchema.set_channel_changeset(attrs)
    |> IntegrationQueries.update()
  end

  @spec delete_integration(SlackIntegrationSchema.t()) ::
          {:ok, SlackIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete_integration(%SlackIntegrationSchema{} = integration),
    do: IntegrationQueries.delete(integration)

  @spec toggle_integration(SlackIntegrationSchema.t()) ::
          {:ok, SlackIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def toggle_integration(%SlackIntegrationSchema{} = integration),
    do: IntegrationQueries.toggle_active(SlackIntegrationSchema, integration)

  @spec record_success(SlackIntegrationSchema.t()) ::
          {:ok, SlackIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def record_success(%SlackIntegrationSchema{} = integration),
    do: IntegrationQueries.record_success(SlackIntegrationSchema, integration)

  @spec increment_failure(SlackIntegrationSchema.t()) ::
          {:ok, SlackIntegrationSchema.t()} | {:error, :not_found}
  def increment_failure(%SlackIntegrationSchema{id: id}),
    do: IntegrationQueries.increment_failure(SlackIntegrationSchema, id)

  @spec enable_integration(SlackIntegrationSchema.t()) ::
          {:ok, SlackIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def enable_integration(%SlackIntegrationSchema{} = integration),
    do: IntegrationQueries.enable(SlackIntegrationSchema, integration)

  # ============================================================================
  # Delivery Queries
  # ============================================================================

  @spec list_deliveries(integer(), keyword()) :: [SlackDeliverySchema.t()]
  def list_deliveries(integration_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    SlackDeliverySchema
    |> where([d], d.integration_id == ^integration_id)
    |> order_by([d], desc: d.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @spec create_delivery(map()) ::
          {:ok, SlackDeliverySchema.t()} | {:error, Ecto.Changeset.t()}
  def create_delivery(attrs) do
    %SlackDeliverySchema{}
    |> SlackDeliverySchema.changeset(attrs)
    |> Repo.insert()
  end

  @spec get_delivery_stats(integer(), keyword()) :: map()
  def get_delivery_stats(integration_id, opts \\ []) do
    days_ago = Keyword.get(opts, :days, 7)
    IntegrationQueries.delivery_stats(SlackDeliverySchema, integration_id, days_ago)
  end

  # ============================================================================
  # Private helpers
  # ============================================================================

  defp active_status?(integration) do
    SlackIntegrationSchema.status(integration) == :active
  end
end
