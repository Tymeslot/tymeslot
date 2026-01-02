defmodule Tymeslot.Security.RateLimiter do
  @moduledoc """
  Simple rate limiter implementation using ETS.
  """

  use GenServer
  require Logger
  alias Tymeslot.Security.AccountLockout

  @table_name :rate_limiter_table
  @type bucket_key :: String.t()
  @type rate_check_result :: {:allow, pos_integer()} | {:deny, pos_integer()}

  @spec start_link(GenServer.options()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  @spec init(term()) :: {:ok, map()}
  def init(_) do
    Logger.info("Starting RateLimiter with ETS table", table: @table_name)
    :ets.new(@table_name, [:named_table, :public, :set])
    {:ok, %{}}
  end

  @impl true
  @spec handle_call(
          {:check_rate, bucket_key(), pos_integer(), pos_integer(), integer(), integer()},
          GenServer.from(),
          map()
        ) :: {:reply, rate_check_result(), map()}
  def handle_call({:check_rate, bucket_key, _window_ms, limit, now, window_start}, _from, state) do
    result =
      case :ets.lookup(@table_name, bucket_key) do
        [] ->
          # First request for this bucket
          :ets.insert(@table_name, {bucket_key, [now]})
          Logger.debug("First request for bucket", bucket_key: bucket_key)
          {:allow, 1}

        [{^bucket_key, timestamps}] ->
          # Filter out old timestamps
          recent_timestamps = Enum.filter(timestamps, fn ts -> ts > window_start end)

          if length(recent_timestamps) >= limit do
            Logger.warning("Rate limit exceeded",
              bucket_key: bucket_key,
              limit: limit,
              current_count: length(recent_timestamps)
            )

            {:deny, limit}
          else
            # Add current timestamp and update
            new_timestamps = [now | recent_timestamps]
            :ets.insert(@table_name, {bucket_key, new_timestamps})

            Logger.debug("Rate limit check passed",
              bucket_key: bucket_key,
              count: length(new_timestamps),
              limit: limit
            )

            {:allow, length(new_timestamps)}
          end
      end

    {:reply, result, state}
  end

  @impl true
  @spec handle_call({:clear_bucket, bucket_key()}, GenServer.from(), map()) ::
          {:reply, :ok, map()}
  def handle_call({:clear_bucket, bucket_key}, _from, state) do
    :ets.delete(@table_name, bucket_key)
    {:reply, :ok, state}
  end

  @impl true
  @spec handle_call(:clear_all, GenServer.from(), map()) :: {:reply, :ok, map()}
  def handle_call(:clear_all, _from, state) do
    :ets.delete_all_objects(@table_name)
    {:reply, :ok, state}
  end

  @doc """
  Check rate limit for a given bucket key.
  Returns {:allow, count} if within limits, {:deny, limit} if exceeded.
  """
  @spec check_rate(bucket_key(), pos_integer(), pos_integer()) :: rate_check_result()
  def check_rate(bucket_key, window_ms, limit) do
    now = System.system_time(:millisecond)
    window_start = now - window_ms

    Logger.debug("Checking rate limit",
      bucket_key: bucket_key,
      window_ms: window_ms,
      limit: limit
    )

    # Use GenServer call for atomic operations
    GenServer.call(__MODULE__, {:check_rate, bucket_key, window_ms, limit, now, window_start})
  end

  @doc """
  Clear rate limit data for a specific bucket key.
  """
  @spec clear_bucket(bucket_key()) :: :ok
  def clear_bucket(bucket_key) do
    GenServer.call(__MODULE__, {:clear_bucket, bucket_key})
  end

  @doc """
  Clear all rate limit data.
  """
  @spec clear_all() :: :ok
  def clear_all do
    GenServer.call(__MODULE__, :clear_all)
  end

  @doc """
  Check rate limit for authentication.
  Returns :ok if allowed, {:error, :rate_limited} if exceeded.
  """
  @spec check_rate_limit(bucket_key(), pos_integer(), pos_integer()) ::
          :ok | {:error, :rate_limited}
  def check_rate_limit(bucket_key, limit, window_ms) do
    case check_rate(bucket_key, window_ms, limit) do
      {:allow, _} -> :ok
      {:deny, _} -> {:error, :rate_limited}
    end
  end

  @doc """
  Check rate limit for password reset requests.
  Returns :allow if allowed, :deny if exceeded.
  """
  @spec check_password_reset(String.t() | :inet.ip_address()) :: :allow | :deny
  def check_password_reset(ip_address) do
    bucket_key = "password_reset:#{inspect(ip_address)}"
    # 20 minutes
    window_ms = 20 * 60 * 1000
    # 6 attempts per 20 minutes
    limit = 6

    case check_rate(bucket_key, window_ms, limit) do
      {:allow, _} -> :allow
      {:deny, _} -> :deny
    end
  end

  # Domain-specific rate limiting functions for account operations

  @doc """
  Rate limit authentication attempts with account lockout.
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.
  """
  @spec check_auth_rate_limit(String.t(), String.t() | nil) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_auth_rate_limit(email, ip \\ nil) do
    with :ok <- AccountLockout.check_lockout_status(email),
         :ok <- check_with_logging("login:#{email}", 10, 1_800_000, "authentication", email),
         :ok <- check_auth_ip_bucket(ip) do
      :ok
    else
      {:error, :account_locked, message} -> {:error, :rate_limited, message}
      {:error, :account_throttled, message} -> {:error, :rate_limited, message}
      error -> error
    end
  end

  # Apply a secondary IP-based throttle to mitigate distributed brute force attempts
  @spec check_auth_ip_bucket(String.t() | :inet.ip_address() | nil | false) ::
          :ok | {:error, :rate_limited, String.t()}
  defp check_auth_ip_bucket(ip) when is_binary(ip) and ip != "" do
    check_with_logging("login_ip:#{ip}", 50, 1_800_000, "authentication (ip)", ip)
  end

  defp check_auth_ip_bucket(_), do: :ok

  @doc """
  Record authentication attempt result for lockout tracking.
  """
  @spec record_auth_attempt(String.t(), boolean()) :: :ok | {:error, atom(), String.t()}
  def record_auth_attempt(email, success) do
    AccountLockout.check_and_record_attempt(email, success)
  end

  @signup_limits [
    {"10m", 5, 10 * 60_000},
    {"1h", 8, 60 * 60_000},
    {"1d", 10, 24 * 60 * 60_000},
    {"1w", 12, 7 * 24 * 60 * 60_000},
    {"1mo", 15, 30 * 24 * 60 * 60_000},
    {"1y", 20, 365 * 24 * 60 * 60_000}
  ]

  @doc """
  Rate limit signup attempts per email and per IP with multi-window buckets.
  """
  @spec check_signup_rate_limit(String.t(), String.t() | :inet.ip_address() | nil) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_signup_rate_limit(email, ip) do
    normalized_ip = normalize_ip(ip)
    downcased_email = String.downcase(email)

    buckets = [
      {"signup:email:#{downcased_email}", @signup_limits, "signup"},
      {"signup:ip:#{normalized_ip}", @signup_limits, "signup"}
    ]

    check_multi_bucket_limits(buckets)
  end

  @verification_limits [
    {"1h", 5, 60 * 60_000},
    {"1d", 10, 24 * 60 * 60_000},
    {"1w", 20, 7 * 24 * 60 * 60_000},
    {"1mo", 25, 30 * 24 * 60 * 60_000},
    {"1y", 50, 365 * 24 * 60 * 60_000}
  ]

  @doc """
  Rate limit email verification/resend attempts per user and per IP.
  """
  @spec check_verification_rate_limit(String.t(), String.t() | :inet.ip_address() | nil) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_verification_rate_limit(user_id, ip) do
    normalized_ip = normalize_ip(ip)

    buckets = [
      {"email_verification:user:#{user_id}", @verification_limits, "email verification"},
      {"email_verification:ip:#{normalized_ip}", @verification_limits, "email verification"}
    ]

    check_multi_bucket_limits(buckets)
  end

  @password_reset_limits [
    {"1h", 5, 60 * 60_000},
    {"1d", 10, 24 * 60 * 60_000},
    {"1w", 20, 7 * 24 * 60 * 60_000},
    {"1mo", 25, 30 * 24 * 60 * 60_000},
    {"1y", 50, 365 * 24 * 60 * 60_000}
  ]

  @doc """
  Rate limit password reset requests per email and per IP.
  """
  @spec check_password_reset_rate_limit(
          String.t(),
          String.t() | :inet.ip_address() | nil
        ) :: :ok | {:error, :rate_limited, String.t()}
  def check_password_reset_rate_limit(email, ip) do
    downcased_email = String.downcase(email)

    buckets =
      maybe_add_ip_bucket([{"password_reset:email:#{downcased_email}", @password_reset_limits, "password reset"}], "password_reset", ip, @password_reset_limits, "password reset")

    check_multi_bucket_limits(buckets)
  end

  @doc """
  Rate limit username change attempts.
  Returns :ok if allowed, {:error, :rate_limited} if exceeded.
  """
  @spec check_username_change_rate_limit(String.t()) ::
          :ok | {:error, :rate_limited}
  def check_username_change_rate_limit(identifier) do
    check_rate_limit("username_change:#{identifier}", 6, 7_200_000)
  end

  @doc """
  Rate limit username availability checks.
  Returns :ok if allowed, {:error, :rate_limited} if exceeded.
  """
  @spec check_username_check_rate_limit(String.t()) :: :ok | {:error, :rate_limited}
  def check_username_check_rate_limit(identifier) do
    check_rate_limit("username_check:#{identifier}", 60, 120_000)
  end

  @doc """
  Rate limit booking submission attempts.
  Returns {:allow, count} if allowed, {:deny, limit} if exceeded.
  """
  @spec check_booking_submission_limit(String.t()) :: rate_check_result()
  def check_booking_submission_limit(client_ip) do
    check_rate("booking_submit:#{client_ip}", 1_200_000, 10)
  end

  @doc """
  Rate limit OAuth initiation attempts (GitHub, Google signup).
  Returns :ok if allowed, {:error, :rate_limited} if exceeded.
  """
  @spec check_oauth_initiation_rate_limit(String.t()) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_oauth_initiation_rate_limit(ip_address) do
    check_with_logging(
      "oauth_initiation:#{ip_address}",
      10,
      600_000,
      "OAuth initiation",
      ip_address
    )
  end

  @doc """
  Rate limit OAuth callback processing.
  Returns :ok if allowed, {:error, :rate_limited} if exceeded.
  """
  @spec check_oauth_callback_rate_limit(String.t()) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_oauth_callback_rate_limit(ip_address) do
    check_with_logging("oauth_callback:#{ip_address}", 20, 120_000, "OAuth callback", ip_address)
  end

  @doc """
  Rate limit OAuth completion form submissions.
  Returns :ok if allowed, {:error, :rate_limited} if exceeded.
  """
  @spec check_oauth_completion_rate_limit(String.t()) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_oauth_completion_rate_limit(ip_address) do
    check_with_logging(
      "oauth_completion:#{ip_address}",
      6,
      1_200_000,
      "OAuth completion",
      ip_address
    )
  end

  @doc """
  Rate limit OAuth registration completion in LiveView.
  Returns :ok if allowed, {:error, :rate_limited} if exceeded.
  """
  @spec check_oauth_registration_rate_limit(String.t()) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_oauth_registration_rate_limit(ip_address) do
    check_with_logging(
      "oauth_registration:#{ip_address}",
      6,
      1_200_000,
      "OAuth registration",
      ip_address
    )
  end

  @doc """
  Rate limit CalDAV connection testing attempts.
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.
  """
  @spec check_caldav_connection_rate_limit(String.t()) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_caldav_connection_rate_limit(ip_address) do
    check_with_logging(
      "caldav_connection:#{ip_address}",
      20,
      600_000,
      "CalDAV connection test",
      ip_address
    )
  end

  @doc """
  Rate limit MiroTalk connection testing attempts.
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.
  """
  @spec check_mirotalk_connection_rate_limit(String.t()) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_mirotalk_connection_rate_limit(ip_address) do
    check_with_logging(
      "mirotalk_connection:#{ip_address}",
      20,
      600_000,
      "MiroTalk connection test",
      ip_address
    )
  end

  @doc """
  Rate limit Nextcloud connection testing attempts.
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.
  """
  @spec check_nextcloud_connection_rate_limit(String.t()) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_nextcloud_connection_rate_limit(ip_address) do
    check_with_logging(
      "nextcloud_connection:#{ip_address}",
      20,
      600_000,
      "Nextcloud connection test",
      ip_address
    )
  end

  @doc """
  Rate limit calendar discovery attempts.
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.
  """
  @spec check_calendar_discovery_rate_limit(String.t()) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_calendar_discovery_rate_limit(ip_address) do
    check_with_logging(
      "calendar_discovery:#{ip_address}",
      30,
      600_000,
      "calendar discovery",
      ip_address
    )
  end

  # Private helper for consistent error handling and logging
  @spec check_with_logging(bucket_key(), pos_integer(), pos_integer(), String.t(), String.t()) ::
          :ok | {:error, :rate_limited, String.t()}
  defp check_with_logging(bucket_key, limit, window, operation, identifier) do
    case check_rate_limit(bucket_key, limit, window) do
      :ok ->
        :ok

      {:error, :rate_limited} ->
        Logger.warning("Rate limit exceeded for #{operation}: #{identifier}")
        {:error, :rate_limited, "Too many #{operation} attempts. Please try again later."}
    end
  end

  defp normalize_ip(nil), do: "unknown"

  defp normalize_ip(ip) when is_tuple(ip) do
    ip |> :inet.ntoa() |> to_string()
  end

  defp normalize_ip(ip) when is_binary(ip), do: ip
  defp normalize_ip(other), do: to_string(other)

  defp maybe_add_ip_bucket(buckets, bucket_prefix, ip, limits, operation)
       when is_list(buckets) and is_binary(bucket_prefix) do
    if ip_present?(ip) do
      normalized_ip = normalize_ip(ip)
      buckets ++ [{"#{bucket_prefix}:ip:#{normalized_ip}", limits, operation}]
    else
      buckets
    end
  end

  defp ip_present?(ip) when is_tuple(ip), do: true
  defp ip_present?(ip) when is_binary(ip), do: ip != ""
  defp ip_present?(_), do: false

  defp check_multi_bucket_limits(buckets) do
    Enum.reduce_while(buckets, :ok, fn {bucket_base, limits, operation}, _ ->
      case apply_limits(bucket_base, limits, operation) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp apply_limits(bucket_base, limits, operation) do
    Enum.reduce_while(limits, :ok, fn {label, limit, window_ms}, _ ->
      case check_rate_limit("#{bucket_base}:#{label}", limit, window_ms) do
        :ok ->
          {:cont, :ok}

        {:error, :rate_limited} ->
          {:halt,
           {:error, :rate_limited,
            "Too many #{operation} attempts. Please try again later."}}
      end
    end)
  end
end
