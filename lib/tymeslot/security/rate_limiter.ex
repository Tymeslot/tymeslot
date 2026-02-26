defmodule Tymeslot.Security.RateLimiter do
  @moduledoc """
  Rate limiter backed by Hammer (ETS sliding window).
  """

  require Logger
  alias Tymeslot.Security.AccountLockout
  alias Tymeslot.Security.RateLimit

  @type bucket_key :: String.t()
  @type rate_check_result :: {:allow, pos_integer()} | {:deny, pos_integer()}

  @doc """
  Check rate limit for a given bucket key.
  Returns {:allow, count} if within limits, {:deny, limit} if exceeded.
  """
  @spec check_rate(bucket_key(), pos_integer(), pos_integer()) :: rate_check_result()
  def check_rate(bucket_key, window_ms, limit) do
    RateLimit.hit(bucket_key, window_ms, limit)
  end

  @doc """
  Clear rate limit data for a specific bucket key.
  """
  @spec clear_bucket(bucket_key()) :: :ok
  def clear_bucket(bucket_key) do
    :ets.match_delete(RateLimit, {{bucket_key, :_}, :_})
    :ok
  end

  @doc """
  Clear all rate limit data.
  """
  @spec clear_all() :: :ok
  def clear_all do
    :ets.delete_all_objects(RateLimit)
    :ok
  end

  @doc """
  Check rate limit for authentication.
  Returns :ok if allowed, {:error, :rate_limited} if exceeded.
  """
  @spec check_rate_limit(bucket_key(), pos_integer(), pos_integer()) ::
          :ok | {:error, :rate_limited}
  def check_rate_limit(bucket_key, limit, window_ms) do
    case check_rate(bucket_key, window_ms, limit) do
      {:allow, _count} -> :ok
      {:deny, _retry_after} -> {:error, :rate_limited}
    end
  end

  @doc """
  Check rate limit for webhook endpoint.

  Limit: 100 requests per 10 minutes per IP

  ## Parameters
    * `client_ip` - The client IP address

  ## Returns
    * `:ok` - Request allowed
    * `{:error, :rate_limited}` - Rate limit exceeded
  """
  @spec check_webhook_rate_limit(String.t()) :: :ok | {:error, :rate_limited}
  def check_webhook_rate_limit(client_ip) do
    check_rate_limit("webhook:#{client_ip}", 100, :timer.minutes(10))
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

  defp check_auth_ip_bucket(_invalid_ip), do: :ok

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
    normalized_ip = normalize_ip(ip)

    buckets = [
      {"password_reset:email:#{downcased_email}", @password_reset_limits, "password reset"},
      {"password_reset:ip:#{normalized_ip}", @password_reset_limits, "password reset"}
    ]

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

  @doc """
  Rate limit payment initiation attempts.
  Returns :ok if allowed, {:error, :rate_limited} if exceeded.

  Prevents abuse by limiting how often users can initiate payment or subscription checkouts.
  This protects against API spam and potential DoS attacks via the payment endpoint.
  """
  @spec check_payment_initiation_rate_limit(integer()) ::
          :ok | {:error, :rate_limited}
  def check_payment_initiation_rate_limit(user_id) do
    config = Application.get_env(:tymeslot, :payment_rate_limits, [])
    max_attempts = Keyword.get(config, :max_attempts, 5)
    window_ms = Keyword.get(config, :window_ms, 600_000)

    bucket_key = "payment_initiation:user:#{user_id}"
    check_rate_limit(bucket_key, max_attempts, window_ms)
  end

  @doc """
  Rate limit meeting cancellation attempts.
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.

  Prevents abuse by limiting how often meeting cancellation actions can be performed.
  Generous limit of 10 cancellations per 10 minutes per IP to avoid impacting legitimate users.
  """
  @spec check_meeting_cancel_rate_limit(String.t()) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_meeting_cancel_rate_limit(client_ip) do
    check_with_logging(
      "meeting_cancel:#{client_ip}",
      10,
      600_000,
      "meeting cancellation",
      client_ip
    )
  end

  @doc """
  Rate limit meeting keep/uncancel attempts.
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.

  Prevents abuse by limiting how often meeting keep actions can be performed.
  Generous limit of 10 keep actions per 10 minutes per IP to avoid impacting legitimate users.
  """
  @spec check_meeting_keep_rate_limit(String.t()) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_meeting_keep_rate_limit(client_ip) do
    check_with_logging(
      "meeting_keep:#{client_ip}",
      10,
      600_000,
      "meeting keep",
      client_ip
    )
  end

  @doc """
  Rate limit theme customization changes (color schemes, backgrounds).
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded,
  or {:error, :invalid_user_id} if user_id is invalid.

  Prevents abuse by limiting how often theme customization changes can be made.

  ## Rate Limit Configuration

  - Limit: 150 changes per 5 minutes per user
  - Rationale: Allows legitimate customization workflow where users try multiple
    colors/backgrounds rapidly to find their preferred design (~30-40 changes in
    active session). Adjusted from initial 50 to reduce false positives based on
    expected UX patterns.
  - Scope: All theme changes (colors + backgrounds) share same bucket to prevent
    overall abuse while allowing natural exploration workflow.

  ## Error Responses

  - `:ok` - Request allowed
  - `{:error, :rate_limited, message}` - Rate limit exceeded
  - `{:error, :invalid_user_id}` - Invalid user_id provided
  """
  @spec check_theme_customization_rate_limit(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_theme_customization_rate_limit(user_id) when is_integer(user_id) and user_id > 0 do
    check_with_logging(
      "theme_customization:#{user_id}",
      150,
      300_000,
      "theme customization",
      to_string(user_id)
    )
  end

  def check_theme_customization_rate_limit(user_id),
    do: invalid_user_id("theme customization", user_id)

  @doc """
  Rate limit meeting filter changes in dashboard.
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.

  Prevents abuse by limiting how often filter changes can be made.
  Generous limit of 100 filter changes per 5 minutes per user to allow normal browsing.
  """
  @spec check_meeting_filter_rate_limit(integer()) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_meeting_filter_rate_limit(user_id) do
    check_with_logging(
      "meeting_filter:#{user_id}",
      100,
      300_000,
      "meeting filter",
      to_string(user_id)
    )
  end

  @doc """
  Rate limit webhook create/update operations from the dashboard.
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.

  Limit: 30 writes per 30 minutes per user.
  """
  @spec check_webhook_write_rate_limit(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_webhook_write_rate_limit(user_id) when is_integer(user_id) and user_id > 0 do
    check_with_logging(
      "webhook_write:#{user_id}",
      30,
      1_800_000,
      "webhook write",
      to_string(user_id)
    )
  end

  def check_webhook_write_rate_limit(user_id), do: invalid_user_id("webhook write", user_id)

  @doc """
  Rate limit webhook test-connection operations from the dashboard.
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.

  Limit: 30 tests per 5 minutes per user.
  """
  @spec check_webhook_test_rate_limit(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_webhook_test_rate_limit(user_id) when is_integer(user_id) and user_id > 0 do
    check_with_logging("webhook_test:#{user_id}", 30, 300_000, "webhook test", to_string(user_id))
  end

  def check_webhook_test_rate_limit(user_id), do: invalid_user_id("webhook test", user_id)

  @doc """
  Rate limit webhook security token regeneration from the dashboard.
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.

  Limit: 10 regenerations per hour per user.
  """
  @spec check_webhook_token_regen_rate_limit(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_webhook_token_regen_rate_limit(user_id) when is_integer(user_id) and user_id > 0 do
    check_with_logging(
      "webhook_token_regen:#{user_id}",
      10,
      3_600_000,
      "webhook token regeneration",
      to_string(user_id)
    )
  end

  def check_webhook_token_regen_rate_limit(user_id),
    do: invalid_user_id("webhook token regeneration", user_id)

  @doc """
  Rate limit the "refresh all calendars" operation from the dashboard.
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.

  Limit: 10 refreshes per 10 minutes per user.
  """
  @spec check_calendar_refresh_rate_limit(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_calendar_refresh_rate_limit(user_id) when is_integer(user_id) and user_id > 0 do
    check_with_logging(
      "calendar_refresh:#{user_id}",
      10,
      600_000,
      "calendar refresh",
      to_string(user_id)
    )
  end

  def check_calendar_refresh_rate_limit(user_id), do: invalid_user_id("calendar refresh", user_id)

  @doc """
  Rate limit calendar and video integration write operations (add/toggle) from the dashboard.
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.

  Limit: 30 writes per 30 minutes per user.
  """
  @spec check_integration_write_rate_limit(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_integration_write_rate_limit(user_id) when is_integer(user_id) and user_id > 0 do
    check_with_logging(
      "integration_write:#{user_id}",
      30,
      1_800_000,
      "integration write",
      to_string(user_id)
    )
  end

  def check_integration_write_rate_limit(user_id),
    do: invalid_user_id("integration write", user_id)

  @doc """
  Rate limit meeting type write operations (create, update, toggle, delete, reorder) from the dashboard.
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.

  Limit: 60 writes per 30 minutes per user.
  """
  @spec check_meeting_type_write_rate_limit(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_meeting_type_write_rate_limit(user_id) when is_integer(user_id) and user_id > 0 do
    check_with_logging(
      "meeting_type_write:#{user_id}",
      60,
      1_800_000,
      "meeting type write",
      to_string(user_id)
    )
  end

  def check_meeting_type_write_rate_limit(user_id),
    do: invalid_user_id("meeting type write", user_id)

  @doc """
  Rate limit avatar upload and delete operations from the dashboard.
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.

  Limit: 20 uploads per hour per user.
  """
  @spec check_avatar_upload_rate_limit(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_avatar_upload_rate_limit(user_id) when is_integer(user_id) and user_id > 0 do
    check_with_logging(
      "avatar_upload:#{user_id}",
      20,
      3_600_000,
      "avatar upload",
      to_string(user_id)
    )
  end

  def check_avatar_upload_rate_limit(user_id), do: invalid_user_id("avatar upload", user_id)

  @doc """
  Rate limit owner-side meeting cancellation from the dashboard.
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.

  Limit: 20 cancellations per 10 minutes per user.
  """
  @spec check_dashboard_cancel_rate_limit(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_dashboard_cancel_rate_limit(user_id) when is_integer(user_id) and user_id > 0 do
    check_with_logging(
      "dashboard_cancel:#{user_id}",
      20,
      600_000,
      "meeting cancellation",
      to_string(user_id)
    )
  end

  def check_dashboard_cancel_rate_limit(user_id),
    do: invalid_user_id("meeting cancellation", user_id)

  @doc """
  Rate limit owner-side reschedule request sending from the dashboard.
  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.

  Limit: 20 reschedule requests per 10 minutes per user.
  """
  @spec check_dashboard_reschedule_rate_limit(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_dashboard_reschedule_rate_limit(user_id) when is_integer(user_id) and user_id > 0 do
    check_with_logging(
      "dashboard_reschedule:#{user_id}",
      20,
      600_000,
      "reschedule request",
      to_string(user_id)
    )
  end

  def check_dashboard_reschedule_rate_limit(user_id),
    do: invalid_user_id("reschedule request", user_id)

  # Private helpers

  @spec invalid_user_id(String.t(), any()) :: {:error, :invalid_user_id}
  defp invalid_user_id(operation, user_id) do
    Logger.error("Invalid user_id for rate limit",
      operation: operation,
      user_id: inspect(user_id)
    )

    {:error, :invalid_user_id}
  end

  @spec check_with_logging(bucket_key(), pos_integer(), pos_integer(), String.t(), String.t()) ::
          :ok | {:error, :rate_limited, String.t()}
  defp check_with_logging(bucket_key, limit, window_ms, operation, identifier) do
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

        message =
          "You've reached the limit of #{limit} #{operation} actions per #{window_minutes} minutes. " <>
            "Please wait a few minutes before trying again."

        {:error, :rate_limited, message}
    end
  end

  defp normalize_ip(nil), do: "unknown"

  defp normalize_ip(ip) when is_tuple(ip) do
    ip |> :inet.ntoa() |> to_string()
  end

  defp normalize_ip(ip) when is_binary(ip), do: ip
  defp normalize_ip(other), do: to_string(other)

  defp check_multi_bucket_limits(buckets) do
    Enum.reduce_while(buckets, :ok, fn {bucket_base, limits, operation}, _acc ->
      case apply_limits(bucket_base, limits, operation) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

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
