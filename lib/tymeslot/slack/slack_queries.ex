defmodule Tymeslot.Slack.SlackQueries do
  @moduledoc """
  Database queries for Slack integrations and deliveries.
  """

  import Ecto.Query, warn: false

  alias Tymeslot.Repo
  alias Tymeslot.Slack.{SlackDeliverySchema, SlackIntegrationSchema}

  # ============================================================================
  # Integration Queries
  # ============================================================================

  @stub_ttl_minutes 30

  @spec list_integrations(integer()) :: [SlackIntegrationSchema.t()]
  def list_integrations(user_id) do
    SlackIntegrationSchema
    |> where([i], i.user_id == ^user_id)
    |> order_by([i], desc: i.inserted_at)
    |> Repo.all()
  end

  @spec delete_pending_stubs(integer()) :: {non_neg_integer(), nil | [term()]}
  def delete_pending_stubs(user_id) do
    SlackIntegrationSchema
    |> where([i], i.user_id == ^user_id)
    |> where([i], i.app_mode == "oauth")
    |> where([i], is_nil(i.channel_id))
    |> Repo.delete_all()
  end

  @doc """
  Deletes every OAuth stub for the user that has a bot token but no channel
  yet — i.e. previous OAuth dances the user never completed. Run this before
  inserting a fresh stub so a user who restarts the install flow does not
  accumulate orphaned rows.
  """
  @spec delete_pending_oauth_stubs_for_user(integer()) ::
          {non_neg_integer(), nil | [term()]}
  def delete_pending_oauth_stubs_for_user(user_id) do
    SlackIntegrationSchema
    |> where([i], i.user_id == ^user_id)
    |> where([i], i.app_mode == "oauth")
    |> where([i], not is_nil(i.bot_token_encrypted))
    |> where([i], is_nil(i.channel_id))
    |> Repo.delete_all()
  end

  @spec cleanup_orphaned_stubs(integer()) :: {non_neg_integer(), nil | [term()]}
  def cleanup_orphaned_stubs(user_id) do
    cutoff = DateTime.add(DateTime.utc_now(), -@stub_ttl_minutes * 60, :second)

    SlackIntegrationSchema
    |> where([i], i.user_id == ^user_id)
    |> where([i], i.app_mode == "oauth")
    |> where([i], is_nil(i.channel_id))
    |> where([i], i.inserted_at < ^cutoff)
    |> Repo.delete_all()
  end

  @spec list_active_integrations_for_event(integer(), String.t()) :: [
          SlackIntegrationSchema.t()
        ]
  def list_active_integrations_for_event(user_id, event_type) do
    SlackIntegrationSchema
    |> where([i], i.user_id == ^user_id)
    |> where([i], i.is_active == true)
    |> where([i], is_nil(i.disabled_at))
    |> where([i], fragment("? = ANY(?)", ^event_type, i.events))
    |> Repo.all()
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
  def get_integration(id, user_id) do
    case Repo.get_by(SlackIntegrationSchema, id: id, user_id: user_id) do
      nil -> {:error, :not_found}
      integration -> {:ok, integration}
    end
  end

  @spec get_integration(integer()) ::
          {:ok, SlackIntegrationSchema.t()} | {:error, :not_found}
  def get_integration(id) do
    case Repo.get(SlackIntegrationSchema, id) do
      nil -> {:error, :not_found}
      integration -> {:ok, integration}
    end
  end

  @spec create_integration(map()) ::
          {:ok, SlackIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def create_integration(attrs) do
    %SlackIntegrationSchema{}
    |> SlackIntegrationSchema.changeset(attrs)
    |> Repo.insert()
  end

  @spec create_oauth_stub(map()) ::
          {:ok, SlackIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def create_oauth_stub(attrs) do
    %SlackIntegrationSchema{}
    |> SlackIntegrationSchema.oauth_init_changeset(attrs)
    |> Repo.insert()
  end

  @spec update_integration(SlackIntegrationSchema.t(), map()) ::
          {:ok, SlackIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_integration(%SlackIntegrationSchema{} = integration, attrs) do
    integration
    |> SlackIntegrationSchema.changeset(attrs)
    |> Repo.update()
  end

  @spec set_channel(SlackIntegrationSchema.t(), map()) ::
          {:ok, SlackIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def set_channel(%SlackIntegrationSchema{} = integration, attrs) do
    integration
    |> SlackIntegrationSchema.set_channel_changeset(attrs)
    |> Repo.update()
  end

  @spec delete_integration(SlackIntegrationSchema.t()) ::
          {:ok, SlackIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete_integration(%SlackIntegrationSchema{} = integration) do
    Repo.delete(integration)
  end

  @spec toggle_integration(SlackIntegrationSchema.t()) ::
          {:ok, SlackIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def toggle_integration(%SlackIntegrationSchema{} = integration) do
    update_integration(integration, %{is_active: !integration.is_active})
  end

  @spec record_success(SlackIntegrationSchema.t()) ::
          {:ok, SlackIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def record_success(%SlackIntegrationSchema{} = integration) do
    update_integration(integration, %{
      last_triggered_at: DateTime.utc_now(),
      failure_count: 0
    })
  end

  @spec increment_failure(SlackIntegrationSchema.t()) ::
          {:ok, SlackIntegrationSchema.t()} | {:error, :not_found}
  def increment_failure(%SlackIntegrationSchema{id: id}) do
    case SlackIntegrationSchema
         |> where([i], i.id == ^id)
         |> select([i], i)
         |> Repo.update_all(inc: [failure_count: 1]) do
      {0, _rows} ->
        {:error, :not_found}

      {_count, [updated]} ->
        {:ok, updated}
    end
  end

  @spec enable_integration(SlackIntegrationSchema.t()) ::
          {:ok, SlackIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def enable_integration(%SlackIntegrationSchema{} = integration) do
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
    since = DateTime.add(DateTime.utc_now(), -days_ago, :day)

    %{total: total, successful: successful, failed: failed} =
      Repo.one(
        from d in SlackDeliverySchema,
          where: d.integration_id == ^integration_id and d.inserted_at >= ^since,
          select: %{
            total: count(d.id),
            successful: filter(count(d.id), d.response_status >= 200 and d.response_status < 300),
            failed: filter(count(d.id), d.response_status >= 400 or not is_nil(d.error_message))
          }
      )

    %{
      total: total,
      successful: successful,
      failed: failed,
      success_rate: if(total > 0, do: Float.round(successful / total * 100, 1), else: 0.0),
      period_days: days_ago
    }
  end

  # ============================================================================
  # Private helpers
  # ============================================================================

  defp active_status?(integration) do
    SlackIntegrationSchema.status(integration) == :active
  end
end
