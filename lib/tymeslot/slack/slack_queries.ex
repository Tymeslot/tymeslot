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

  @spec list_integrations(integer()) :: [SlackIntegrationSchema.t()]
  def list_integrations(user_id),
    do: IntegrationQueries.list_for_user(SlackIntegrationSchema, user_id)

  @doc """
  Whether a user other than `user_id` holds a bot token for the Slack
  workspace `team_id`. Slack issues one bot token per workspace for the app,
  so every account that connected the same workspace holds the same token.
  """
  @spec workspace_token_shared?(String.t(), integer()) :: boolean()
  def workspace_token_shared?(team_id, user_id) when is_binary(team_id) do
    SlackIntegrationSchema
    |> where([s], s.team_id == ^team_id and s.user_id != ^user_id)
    |> where([s], not is_nil(s.bot_token_encrypted))
    |> Repo.exists?()
  end

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

  @doc """
  Deletes OAuth installs never finished by picking a channel and created
  before `cutoff`, across all users.

  "Never finished" is a row written once and never since: picking a channel
  writes it, and so does disconnecting a finished integration back to
  pending (`disconnect/1`), so a user's disconnected integration is kept.
  """
  @spec delete_stale_pending_stubs(DateTime.t()) :: {non_neg_integer(), nil | [term()]}
  def delete_stale_pending_stubs(cutoff) do
    SlackIntegrationSchema
    |> where([i], i.app_mode == "oauth")
    |> where([i], is_nil(i.channel_id))
    |> where([i], i.updated_at == i.inserted_at)
    |> where([i], i.inserted_at < ^cutoff)
    |> Repo.delete_all()
  end

  @spec list_active_integrations_for_event(integer(), String.t()) :: [
          SlackIntegrationSchema.t()
        ]
  def list_active_integrations_for_event(user_id, event_type) do
    SlackIntegrationSchema
    |> IntegrationQueries.list_active_for_event(user_id, event_type)
    |> Enum.filter(&active_status?/1)
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
    attrs
    |> SlackIntegrationSchema.create_changeset()
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
    |> SlackIntegrationSchema.user_changeset(attrs)
    |> IntegrationQueries.update()
  end

  @doc """
  Applies a state-transition-only update (active/disabled flags, failure count,
  last-triggered stamp) without running full validation or re-encrypting
  credentials. Safe to call on records in any state, including pending stubs
  where `channel_id` or `bot_token` may be nil.
  """
  @spec update_state(SlackIntegrationSchema.t(), map()) ::
          {:ok, SlackIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_state(%SlackIntegrationSchema{} = integration, attrs) do
    integration
    |> SlackIntegrationSchema.state_transition_changeset(attrs)
    |> IntegrationQueries.update()
  end

  @spec set_channel(SlackIntegrationSchema.t(), map()) ::
          {:ok, SlackIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def set_channel(%SlackIntegrationSchema{} = integration, attrs) do
    integration
    |> SlackIntegrationSchema.set_channel_changeset(attrs)
    |> IntegrationQueries.update()
  end

  @doc """
  Clears the channel selection on an OAuth integration, demoting it back to
  `:pending_oauth`. Uses `disconnect_changeset/1` so the operation is safe on
  records that would otherwise fail full revalidation.
  """
  @spec disconnect(SlackIntegrationSchema.t()) ::
          {:ok, SlackIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def disconnect(%SlackIntegrationSchema{} = integration) do
    integration
    |> SlackIntegrationSchema.disconnect_changeset()
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
  def list_deliveries(integration_id, opts),
    do:
      IntegrationQueries.list_deliveries(
        SlackDeliverySchema,
        :integration_id,
        integration_id,
        opts
      )

  @spec create_delivery(map()) :: {:ok, SlackDeliverySchema.t()} | {:error, Ecto.Changeset.t()}
  def create_delivery(attrs), do: IntegrationQueries.create_delivery(SlackDeliverySchema, attrs)

  @spec get_delivery_stats(integer(), keyword()) :: map()
  def get_delivery_stats(integration_id, opts \\ []) do
    IntegrationQueries.delivery_stats(
      SlackDeliverySchema,
      :integration_id,
      integration_id,
      Keyword.get(opts, :days, 7)
    )
  end

  @doc "Deletes Slack delivery log rows older than `days`; see `IntegrationQueries.cleanup_old_deliveries/2`."
  @spec cleanup_old_deliveries(integer()) :: {non_neg_integer(), nil}
  def cleanup_old_deliveries(days),
    do: IntegrationQueries.cleanup_old_deliveries(SlackDeliverySchema, days)

  # ============================================================================
  # Private helpers
  # ============================================================================

  defp active_status?(integration) do
    SlackIntegrationSchema.status(integration) == :active
  end
end
