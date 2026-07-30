defmodule Tymeslot.Payments.Webhooks.IdempotencyCache do
  @moduledoc """
  Two-tier idempotency cache for webhook event deduplication.

  - **Tier 1 (ETS)**: Fast in-memory cache for recent events (24 hours)
  - **Tier 2 (Database)**: Persistent storage for long-term deduplication (90 days)

  `reserve/1` is the production entry point. On an ETS miss (cold cache after
  a restart, or an entry that fell out of the 24h TTL) it falls through to
  the database tier before granting a fresh reservation, so an event already
  recorded in the (up to 90-day) `webhook_events` table is never handed out
  as `:reserved` again.

  Uses the centralized CacheStore infrastructure for ETS tier.
  """

  require Logger

  alias Tymeslot.Infrastructure.CacheStore
  alias Tymeslot.Webhooks.WebhookQueries

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
        # Check database as fallback. Fails open on a database error, same
        # choice as `confirm_reservation/1` below, to keep this function's
        # contract (never returns an `:error` tuple) honest.
        case check_database(event_id) do
          {:ok, result} -> {:ok, result}
          {:error, _reason} -> {:ok, :not_processed}
        end
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

    if :ets.insert_new(:webhook_idempotency_cache, {event_id, :processing, expiry}) do
      confirm_reservation(event_id)
    else
      reserve_existing(event_id, expiry)
    end
  end

  defp reserve_existing(event_id, expiry) do
    case lookup_entry(event_id) do
      {:ok, :processing} ->
        {:ok, :in_progress}

      {:ok, :processed} ->
        {:ok, :already_processed}

      :miss ->
        # Entry expired but wasn't cleaned yet; clear and try again
        :ets.delete(:webhook_idempotency_cache, event_id)

        if :ets.insert_new(:webhook_idempotency_cache, {event_id, :processing, expiry}) do
          confirm_reservation(event_id)
        else
          {:ok, :in_progress}
        end
    end
  end

  # ETS granted a fresh `:processing` slot, but that only means this event
  # hasn't been seen since the cache was last empty (process restart) or
  # within the last `processed_ttl` (default 24h). Consult the database —
  # the durable, 90-day tier — before actually treating it as new. This adds
  # one query per genuinely-new event, which is the accepted cost of closing
  # the gap between the two tiers' retention windows.
  defp confirm_reservation(event_id) do
    case check_database(event_id) do
      {:ok, :not_processed} ->
        {:ok, :reserved}

      {:ok, :already_processed} ->
        # Repopulate the ETS entry so subsequent callers get the fast path.
        put(event_id, :processed, processed_ttl())
        {:ok, :already_processed}

      {:error, reason} ->
        # Fail open: an unreachable database must not take down webhook
        # processing entirely. The ETS `:processing` slot already reserved
        # above still prevents duplicate concurrent processing within this
        # node's uptime; the worst case here is reprocessing an event that
        # was already handled more than `processed_ttl` ago, which is the
        # same exposure this cache had before the database tier existed.
        Logger.error("IdempotencyCache: database check failed, failing open",
          event_id: event_id,
          error: inspect(reason)
        )

        {:ok, :reserved}
    end
  end

  @doc """
  Mark an event as processed in both cache and database.

  Optionally accepts the full event payload for post-hoc debugging.
  """
  @spec mark_processed(String.t(), String.t() | nil, map() | nil) :: :ok
  def mark_processed(event_id, event_type \\ "unknown", payload \\ nil) do
    event_type = event_type || "unknown"
    # Mark as processed in ETS cache with configured TTL (default 24 hours)
    put(event_id, :processed, processed_ttl())

    # Also store in database for long-term deduplication
    store_in_database(event_id, event_type, payload)
    :ok
  end

  @doc """
  Clear all cached events and database records.
  """
  @spec clear_all() :: :ok
  def clear_all do
    # Clear ETS cache first
    :ets.delete_all_objects(:webhook_idempotency_cache)

    # Clear database
    WebhookQueries.delete_all_webhook_events()
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
      _miss -> :miss
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
    case WebhookQueries.get_webhook_event_by_stripe_id(event_id) do
      nil -> {:ok, :not_processed}
      _existing -> {:ok, :already_processed}
    end
  rescue
    error -> {:error, error}
  end

  defp store_in_database(event_id, event_type, payload) do
    attrs = %{
      stripe_event_id: event_id,
      event_type: event_type,
      payload: payload,
      processed_at: DateTime.utc_now(:second)
    }

    WebhookQueries.upsert_webhook_event(attrs)
    :ok
  end
end
