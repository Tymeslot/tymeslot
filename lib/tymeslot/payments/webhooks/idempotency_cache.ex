defmodule Tymeslot.Payments.Webhooks.IdempotencyCache do
  @moduledoc """
  Two-tier idempotency cache for webhook event deduplication.

  - **Tier 1 (ETS)**: Fast in-memory cache for recent events (24 hours)
  - **Tier 2 (Database)**: Persistent storage for long-term deduplication (90 days)

  Uses the centralized CacheStore infrastructure for ETS tier.
  """

  alias Tymeslot.DatabaseSchemas.WebhookEventSchema, as: WebhookEvent
  alias Tymeslot.Infrastructure.CacheStore
  alias Tymeslot.Repo

  import Ecto.Query

  use CacheStore,
    table_name: :webhook_idempotency_cache,
    default_ttl:
      get_in(Application.compile_env(:tymeslot, :webhook_idempotency, []), [:processed_ttl_ms]) ||
        :timer.hours(24),
    cleanup_interval: :timer.hours(1)

  @doc """
  Check if an event has already been processed.

  Checks two tiers:
  1. ETS cache (fast, 24 hours)
  2. Database (slower, 90 days)

  Returns {:ok, :not_processed} if the event hasn't been seen,
  or {:ok, :already_processed} if it has already been processed.
  """
  @spec check_idempotency(String.t()) :: {:ok, :not_processed | :already_processed}
  def check_idempotency(event_id) do
    case CacheStore.lookup(:webhook_idempotency_cache, event_id) do
      {:ok, _timestamp} ->
        {:ok, :already_processed}

      :miss ->
        # Check database as fallback
        check_database(event_id)
    end
  end

  @doc """
  Atomically reserves an event for processing.
  Returns {:ok, :reserved} if this process should handle it,
  or {:ok, :already_processed} if another process already reserved/processed it.
  """
  @spec reserve(String.t()) :: {:ok, :reserved | :in_progress | :already_processed}
  def reserve(event_id) do
    now = System.monotonic_time(:millisecond)
    expiry = now + processing_ttl()

    case :ets.insert_new(:webhook_idempotency_cache, {event_id, :processing, expiry}) do
      true ->
        {:ok, :reserved}

      false ->
        case lookup_entry(event_id) do
          {:ok, :processing} ->
            {:ok, :in_progress}

          {:ok, :processed} ->
            {:ok, :already_processed}

          :miss ->
            # Entry expired but wasn't cleaned yet; clear and try again
            :ets.delete(:webhook_idempotency_cache, event_id)

            if :ets.insert_new(:webhook_idempotency_cache, {event_id, :processing, expiry}) do
              {:ok, :reserved}
            else
              {:ok, :in_progress}
            end
        end
    end
  end

  @doc """
  Mark an event as processed in both cache and database.
  """
  @spec mark_processed(String.t(), String.t() | nil) :: :ok
  def mark_processed(event_id, event_type \\ "unknown") do
    event_type = event_type || "unknown"
    # Mark as processed in ETS cache with configured TTL (default 24 hours)
    put(event_id, :processed, processed_ttl())

    # Also store in database for long-term deduplication
    store_in_database(event_id, event_type)
    :ok
  end

  @doc """
  Clear all cached events and database records.
  """
  @spec clear_all() :: :ok
  def clear_all do
    # Clear ETS cache first
    :ets.delete_all_objects(:webhook_idempotency_cache)

    # Clear database - always use Tymeslot.Repo
    query = from(w in WebhookEvent)
    Repo.delete_all(query)
    :ok
  end

  @doc """
  Releases a reserved event so it can be retried.
  """
  @spec release(String.t()) :: :ok
  def release(event_id) do
    invalidate(event_id)
    :ok
  end

  defp lookup_entry(event_id) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(:webhook_idempotency_cache, event_id) do
      [{^event_id, value, expiry}] when expiry > now -> {:ok, value}
      _ -> :miss
    end
  end

  # Configuration helpers

  defp processing_ttl do
    get_in(Application.get_env(:tymeslot, :webhook_idempotency, []), [:processing_ttl_ms]) ||
      :timer.minutes(10)
  end

  defp processed_ttl do
    get_in(Application.get_env(:tymeslot, :webhook_idempotency, []), [:processed_ttl_ms]) ||
      :timer.hours(24)
  end

  # Database operations

  defp check_database(event_id) do
    case Repo.get_by(WebhookEvent, stripe_event_id: event_id) do
      nil -> {:ok, :not_processed}
      _event -> {:ok, :already_processed}
    end
  end

  defp store_in_database(event_id, event_type) do
    attrs = %{
      stripe_event_id: event_id,
      event_type: event_type,
      processed_at: DateTime.utc_now(:second)
    }

    changeset = WebhookEvent.changeset(%WebhookEvent{}, attrs)

    Repo.insert(changeset, on_conflict: :nothing, conflict_target: :stripe_event_id)
    :ok
  end
end
