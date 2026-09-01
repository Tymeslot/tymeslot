defmodule Tymeslot.Webhooks.WebhookQueries do
  @moduledoc """
  Database queries for webhooks and webhook deliveries.
  """

  import Ecto.Query, warn: false

  alias Tymeslot.Infrastructure.BatchDeleteQueries
  alias Tymeslot.Repo

  alias Tymeslot.Webhooks.{
    DeliveryStatus,
    WebhookDeliverySchema,
    WebhookEventSchema,
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
    %WebhookSchema{}
    |> WebhookSchema.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a webhook.
  """
  @spec update_webhook(WebhookSchema.t(), map()) ::
          {:ok, WebhookSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_webhook(%WebhookSchema{} = webhook, attrs) do
    webhook
    |> WebhookSchema.changeset(attrs)
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
  def toggle_webhook(%WebhookSchema{} = webhook) do
    update_webhook(webhook, %{is_active: !webhook.is_active})
  end

  @doc """
  Records a successful webhook delivery.
  """
  @spec record_success(WebhookSchema.t(), DateTime.t() | nil) ::
          {:ok, WebhookSchema.t()} | {:error, Ecto.Changeset.t()}
  def record_success(%WebhookSchema{} = webhook, triggered_at \\ nil) do
    triggered_at = triggered_at || DateTime.utc_now()

    update_webhook(webhook, %{
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
    update_webhook(webhook, %{
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
  def enable_webhook(%WebhookSchema{} = webhook) do
    update_webhook(webhook, %{
      is_active: true,
      disabled_at: nil,
      disabled_reason: nil,
      failure_count: 0
    })
  end

  # ============================================================================
  # Webhook Delivery Queries
  # ============================================================================

  @doc """
  Lists webhook deliveries for a specific webhook with pagination.
  """
  @spec list_deliveries(integer(), keyword()) :: [WebhookDeliverySchema.t()]
  def list_deliveries(webhook_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    WebhookDeliverySchema
    |> where([d], d.webhook_id == ^webhook_id)
    |> order_by([d], desc: d.inserted_at)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc """
  Gets a single delivery by ID.
  """
  @spec get_delivery(binary()) ::
          {:ok, WebhookDeliverySchema.t()} | {:error, :not_found}
  def get_delivery(id) do
    case Repo.get(WebhookDeliverySchema, id) do
      nil -> {:error, :not_found}
      delivery -> {:ok, delivery}
    end
  end

  @doc """
  Creates a webhook delivery log entry.
  """
  @spec create_delivery(map()) ::
          {:ok, WebhookDeliverySchema.t()} | {:error, Ecto.Changeset.t()}
  def create_delivery(attrs) do
    %WebhookDeliverySchema{}
    |> WebhookDeliverySchema.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets delivery statistics for a webhook.
  """
  @spec get_delivery_stats(integer(), keyword()) :: map()
  def get_delivery_stats(webhook_id, opts \\ []) do
    days_ago = Keyword.get(opts, :days, 7)
    since = DateTime.add(DateTime.utc_now(), -days_ago, :day)

    query =
      from d in WebhookDeliverySchema,
        where: d.webhook_id == ^webhook_id and d.inserted_at >= ^since

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

  @doc """
  Cleans up old webhook deliveries. Defaults to 30 days but can be
  overridden. Deletes in bounded batches (see `BatchDeleteQueries`) so a
  large backlog can't blow past the database timeout in a single
  transaction. A zero, negative, or non-integer retention is treated as a
  no-op so a misconfigured value can never wipe the whole table.
  """
  @spec cleanup_old_deliveries(integer()) :: {non_neg_integer(), nil}
  def cleanup_old_deliveries(days \\ 30)

  def cleanup_old_deliveries(days) when is_integer(days) and days > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)

    BatchDeleteQueries.delete_older_than(WebhookDeliverySchema, :inserted_at, cutoff)
  end

  def cleanup_old_deliveries(_days), do: {0, nil}

  # ============================================================================
  # Webhook Event Queries (incoming Stripe events)
  # ============================================================================

  @doc """
  Deletes all webhook events.
  """
  @spec delete_all_webhook_events() :: {non_neg_integer(), nil}
  def delete_all_webhook_events do
    Repo.delete_all(WebhookEventSchema)
  end

  @doc """
  Gets a webhook event by its Stripe event ID.
  """
  @spec get_webhook_event_by_stripe_id(String.t()) :: WebhookEventSchema.t() | nil
  def get_webhook_event_by_stripe_id(stripe_event_id) do
    Repo.get_by(WebhookEventSchema, stripe_event_id: stripe_event_id)
  end

  @doc """
  Inserts a webhook event record, doing nothing on conflict with existing stripe_event_id.
  """
  @spec upsert_webhook_event(map()) ::
          {:ok, WebhookEventSchema.t()} | {:error, Ecto.Changeset.t()}
  def upsert_webhook_event(attrs) do
    %WebhookEventSchema{}
    |> WebhookEventSchema.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: :stripe_event_id)
  end

  @doc """
  Nullifies payloads on webhook events older than the given cutoff date.

  Returns `{count, nil}` where count is the number of rows updated.
  """
  @spec nullify_stale_payloads(DateTime.t()) :: {non_neg_integer(), nil}
  def nullify_stale_payloads(%DateTime{} = cutoff_date) do
    query =
      from(w in WebhookEventSchema,
        where: w.inserted_at < ^cutoff_date and not is_nil(w.payload)
      )

    Repo.update_all(query, set: [payload: nil])
  end

  @doc """
  Deletes webhook events older than the given cutoff date.

  Deletes in bounded batches (see `BatchDeleteQueries`) so a large backlog
  can't blow past the database timeout in a single transaction.

  Returns `{count, nil}` where count is the number of rows deleted.
  """
  @spec delete_old_webhook_events(DateTime.t()) :: {non_neg_integer(), nil}
  def delete_old_webhook_events(%DateTime{} = cutoff_date) do
    BatchDeleteQueries.delete_older_than(WebhookEventSchema, :inserted_at, cutoff_date)
  end
end
