defmodule Tymeslot.Webhooks.WebhookQueries do
  @moduledoc """
  Database queries for webhooks and webhook deliveries.
  """

  import Ecto.Query, warn: false

  alias Tymeslot.Notifications.IntegrationQueries
  alias Tymeslot.Repo

  alias Tymeslot.Webhooks.{
    DeliveryStatus,
    WebhookDeliverySchema,
    WebhookSchema
  }

  # ============================================================================
  # Webhook Queries
  # ============================================================================

  @doc """
  Lists all webhooks for a user.
  """
  @spec list_webhooks(integer()) :: [WebhookSchema.t()]
  def list_webhooks(user_id) do
    WebhookSchema
    |> where([w], w.user_id == ^user_id)
    |> order_by([w], desc: w.inserted_at)
    |> Repo.all()
  end

  @doc """
  Lists active webhooks for a user subscribed to a specific event.
  """
  @spec list_active_webhooks_for_event(integer(), String.t()) :: [WebhookSchema.t()]
  def list_active_webhooks_for_event(user_id, event_type) do
    WebhookSchema
    |> where([w], w.user_id == ^user_id)
    |> where([w], w.is_active == true)
    |> where([w], is_nil(w.disabled_at))
    |> where([w], fragment("? = ANY(?)", ^event_type, w.events))
    |> Repo.all()
  end

  @doc """
  Gets a single webhook by ID for a specific user.
  """
  @spec get_webhook(integer(), integer()) :: {:ok, WebhookSchema.t()} | {:error, :not_found}
  def get_webhook(id, user_id) do
    case Repo.get_by(WebhookSchema, id: id, user_id: user_id) do
      nil -> {:error, :not_found}
      webhook -> {:ok, webhook}
    end
  end

  @doc """
  Gets a webhook by ID without user restriction (for internal use).
  """
  @spec get_webhook(integer()) :: {:ok, WebhookSchema.t()} | {:error, :not_found}
  def get_webhook(id) do
    case Repo.get(WebhookSchema, id) do
      nil -> {:error, :not_found}
      webhook -> {:ok, webhook}
    end
  end

  @doc """
  Creates a webhook.
  """
  @spec create_webhook(map()) :: {:ok, WebhookSchema.t()} | {:error, Ecto.Changeset.t()}
  def create_webhook(attrs) do
    attrs
    |> WebhookSchema.create_changeset()
    |> Repo.insert()
  end

  @doc """
  Updates a webhook.
  """
  @spec update_webhook(WebhookSchema.t(), map()) ::
          {:ok, WebhookSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_webhook(%WebhookSchema{} = webhook, attrs) do
    webhook
    |> WebhookSchema.update_changeset(attrs)
    |> Repo.update()
  end

  defp update_state(%WebhookSchema{} = webhook, attrs) do
    webhook
    |> WebhookSchema.state_transition_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a webhook.
  """
  @spec delete_webhook(WebhookSchema.t()) ::
          {:ok, WebhookSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete_webhook(%WebhookSchema{} = webhook) do
    Repo.delete(webhook)
  end

  @doc """
  Toggles webhook active status.
  """
  @spec toggle_webhook(WebhookSchema.t()) ::
          {:ok, WebhookSchema.t()} | {:error, Ecto.Changeset.t()}
  def toggle_webhook(%WebhookSchema{} = webhook),
    do: IntegrationQueries.toggle_active(WebhookSchema, webhook)

  @doc """
  Records a successful webhook delivery.
  """
  @spec record_success(WebhookSchema.t(), DateTime.t() | nil) ::
          {:ok, WebhookSchema.t()} | {:error, Ecto.Changeset.t()}
  def record_success(%WebhookSchema{} = webhook, triggered_at \\ nil) do
    triggered_at = triggered_at || DateTime.utc_now()

    update_state(webhook, %{
      last_triggered_at: triggered_at,
      last_status: DeliveryStatus.encode_success(),
      failure_count: 0
    })
  end

  @doc """
  Atomically increments the failure count and records the failure reason.

  Returns the updated webhook with the new failure count. Does NOT check
  thresholds or auto-disable — that decision belongs in the context module.
  """
  @spec increment_failure_count(WebhookSchema.t(), String.t()) ::
          {:ok, WebhookSchema.t()} | {:error, :not_found}
  def increment_failure_count(%WebhookSchema{id: id}, reason) do
    case WebhookSchema
         |> where([w], w.id == ^id)
         |> select([w], w)
         |> Repo.update_all(
           set: [
             last_status: DeliveryStatus.encode_failure(reason),
             last_triggered_at: DateTime.utc_now(:second)
           ],
           inc: [failure_count: 1]
         ) do
      {0, []} ->
        {:error, :not_found}

      {1, [updated_webhook]} ->
        {:ok, updated_webhook}
    end
  end

  @doc """
  Disables a webhook with a reason.
  """
  @spec disable_webhook(WebhookSchema.t(), String.t()) ::
          {:ok, WebhookSchema.t()} | {:error, Ecto.Changeset.t()}
  def disable_webhook(%WebhookSchema{} = webhook, reason) do
    update_state(webhook, %{
      is_active: false,
      disabled_at: DateTime.utc_now(),
      disabled_reason: reason
    })
  end

  @doc """
  Re-enables a disabled webhook (resets failure count).
  """
  @spec enable_webhook(WebhookSchema.t()) ::
          {:ok, WebhookSchema.t()} | {:error, Ecto.Changeset.t()}
  def enable_webhook(%WebhookSchema{} = webhook),
    do: IntegrationQueries.enable(WebhookSchema, webhook)

  # ============================================================================
  # Webhook Delivery Queries
  # ============================================================================

  @spec list_deliveries(integer(), keyword()) :: [WebhookDeliverySchema.t()]
  def list_deliveries(webhook_id, opts),
    do: IntegrationQueries.list_deliveries(WebhookDeliverySchema, :webhook_id, webhook_id, opts)

  @spec create_delivery(map()) :: {:ok, WebhookDeliverySchema.t()} | {:error, Ecto.Changeset.t()}
  def create_delivery(attrs), do: IntegrationQueries.create_delivery(WebhookDeliverySchema, attrs)

  @spec get_delivery_stats(integer(), keyword()) :: map()
  def get_delivery_stats(webhook_id, opts \\ []) do
    IntegrationQueries.delivery_stats(
      WebhookDeliverySchema,
      :webhook_id,
      webhook_id,
      Keyword.get(opts, :days, 7)
    )
  end

  @doc "Deletes webhook delivery log rows older than `days`; see `IntegrationQueries.cleanup_old_deliveries/2`."
  @spec cleanup_old_deliveries(integer()) :: {non_neg_integer(), nil}
  def cleanup_old_deliveries(days),
    do: IntegrationQueries.cleanup_old_deliveries(WebhookDeliverySchema, days)
end
