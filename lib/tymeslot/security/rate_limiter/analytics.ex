defmodule Tymeslot.Security.RateLimiter.Analytics do
  @moduledoc """
  Rate limits for the analytics event ingestion path.

  Limits writes per visitor_hash so a single visitor that aggressively
  navigates booking pages (or a scraper that bypassed UA filtering)
  cannot flood the events table.
  """

  alias Tymeslot.Security.RateLimiter.Helpers

  # 30 events per minute per visitor — a real visitor cannot click that fast
  @window_ms 60_000
  @limit 30

  @spec check(String.t()) :: {:allow, pos_integer()} | {:deny, pos_integer()}
  def check(visitor_hash) when is_binary(visitor_hash) do
    Helpers.check_rate("analytics:visitor:" <> visitor_hash, @window_ms, @limit)
  end

  @spec check_ip(String.t(), pos_integer(), pos_integer()) ::
          {:allow, pos_integer()} | {:deny, pos_integer()}
  def check_ip(bucket_key, window_ms, limit) when is_binary(bucket_key) do
    Helpers.check_rate(bucket_key, window_ms, limit)
  end
end
