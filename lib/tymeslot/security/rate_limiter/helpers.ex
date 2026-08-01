defmodule Tymeslot.Security.RateLimiter.Helpers do
  @moduledoc false

  require Logger

  alias Tymeslot.Security.RateLimit

  @type bucket_key :: String.t()
  @type rate_check_result :: {:allow, pos_integer()} | {:deny, pos_integer()}

  @spec check_rate(bucket_key(), pos_integer(), pos_integer()) :: rate_check_result()
  def check_rate(bucket_key, window_ms, limit) do
    RateLimit.hit(bucket_key, window_ms, limit)
  rescue
    # Hammer 7.2.0 has a TOCTOU race in SlidingWindow.hit/4: when count exceeds
    # the limit, it calls get_earliest_expiry/3 which uses Enum.min/1 on an ETS
    # select result. If the table is cleared concurrently (e.g. in tests), the
    # select returns [] and Enum.min/1 raises Enum.EmptyError. Treat this as a
    # deny — the bucket was already over limit at the moment the race occurred.
    #
    # The race is a known upstream defect with a fully understood outcome, and it
    # fires on the hot path of every rate-limited request, so logging it would be
    # noise rather than evidence.
    # credo:disable-for-next-line CredoChecks.NoSwallowedException
    Enum.EmptyError -> {:deny, 0}
  end

  @spec check_rate_limit(bucket_key(), pos_integer(), pos_integer()) ::
          :ok | {:error, :rate_limited}
  def check_rate_limit(bucket_key, limit, window_ms) do
    case check_rate(bucket_key, window_ms, limit) do
      {:allow, _count} -> :ok
      {:deny, _retry_after} -> {:error, :rate_limited}
    end
  end

  @spec check_with_logging(bucket_key(), pos_integer(), pos_integer(), String.t(), String.t()) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_with_logging(bucket_key, limit, window_ms, operation, identifier) do
    case check_rate_limit(bucket_key, limit, window_ms) do
      :ok ->
        :ok

      {:error, :rate_limited} ->
        window_minutes = div(window_ms, 60_000)

        Logger.warning("Rate limit exceeded",
          operation: operation,
          identifier: identifier,
          bucket: bucket_key,
          limit: limit,
          window_minutes: window_minutes
        )

        {:error, :rate_limited,
         "You've reached the limit of #{limit} #{operation} actions per #{window_minutes} minutes. " <>
           "Please wait a few minutes before trying again."}
    end
  end

  @spec invalid_user_id(String.t(), any()) :: {:error, :invalid_user_id}
  def invalid_user_id(operation, user_id) do
    Logger.error("Invalid user_id for rate limit",
      operation: operation,
      user_id: inspect(user_id)
    )

    {:error, :invalid_user_id}
  end

  @spec normalize_ip(nil | :inet.ip_address() | binary() | any()) :: String.t()
  def normalize_ip(nil), do: "unknown"

  def normalize_ip(ip) when is_tuple(ip) do
    ip |> :inet.ntoa() |> to_string()
  end

  def normalize_ip(ip) when is_binary(ip), do: ip
  def normalize_ip(other), do: to_string(other)

  @spec check_multi_bucket_limits(list()) :: :ok | {:error, :rate_limited, String.t()}
  def check_multi_bucket_limits(buckets) do
    Enum.reduce_while(buckets, :ok, fn {bucket_base, limits, operation}, _acc ->
      case apply_limits(bucket_base, limits, operation) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @spec apply_limits(bucket_key(), list(), String.t()) ::
          :ok | {:error, :rate_limited, String.t()}
  defp apply_limits(bucket_base, limits, operation) do
    Enum.reduce_while(limits, :ok, fn {label, limit, window_ms}, _acc ->
      case check_rate_limit("#{bucket_base}:#{label}", limit, window_ms) do
        :ok ->
          {:cont, :ok}

        {:error, :rate_limited} ->
          {:halt,
           {:error, :rate_limited, "Too many #{operation} attempts. Please try again later."}}
      end
    end)
  end
end
