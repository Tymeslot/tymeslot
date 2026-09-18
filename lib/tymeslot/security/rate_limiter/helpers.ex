defmodule Tymeslot.Security.RateLimiter.Helpers do
  @moduledoc false

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Security.RateLimit
  alias Tymeslot.Security.SecurityLogger

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

  @doc """
  Charges one token and, on a refusal, logs it and builds the copy the person
  reads.

  `operation` names the *bucket*, and is for the log line only. `action` names
  what the person actually did, already localised by the caller, and is what
  the refusal says out loud. The two are not the same thing: several actions
  share one bucket, so deriving the sentence from the bucket tells someone who
  pressed "Add" that they ran too many connection tests. A caller with only one
  action per bucket passes `nil` and gets the operation label back.

  The wait comes from the limiter rather than the window: the window is how
  long the budget spans, which is an upper bound on the wait and usually a wild
  overestimate of it.
  """
  @spec check_with_logging(
          bucket_key(),
          pos_integer(),
          pos_integer(),
          String.t(),
          String.t(),
          String.t() | nil
        ) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_with_logging(bucket_key, limit, window_ms, operation, identifier, action \\ nil) do
    case check_rate(bucket_key, window_ms, limit) do
      {:allow, _count} ->
        :ok

      {:deny, retry_after_ms} ->
        window_minutes = div(window_ms, 60_000)

        # Neither the identifier nor the bucket key reaches the log line raw:
        # the login and signup buckets are keyed on the email address, so a
        # rejection under attack would otherwise write it twice per request,
        # on the one path that fires at volume. `operation` already names the
        # bucket, so the bucket key adds nothing but the identifier.
        Logger.warning("Rate limit exceeded",
          operation: operation,
          identifier_masked: mask_identifier(identifier),
          limit: limit,
          window_minutes: window_minutes,
          retry_after_ms: retry_after_ms
        )

        {:error, :rate_limited,
         refusal_message(limit, window_minutes, retry_after_ms, action || "#{operation} actions")}
    end
  end

  defp refusal_message(limit, window_minutes, retry_after_ms, action) do
    dgettext(
      "errors",
      "You've reached the limit of %{limit} %{action} per %{window_minutes} minutes. Please try again in %{wait}.",
      limit: limit,
      action: action,
      window_minutes: window_minutes,
      wait: retry_after_wait(retry_after_ms)
    )
  end

  # Hammer answers in milliseconds, and rounds up rather than down: telling
  # someone to come back in "0 minutes" would send them straight into a second
  # refusal.
  defp retry_after_wait(retry_after_ms) when is_integer(retry_after_ms) and retry_after_ms > 0 do
    minutes = max(1, ceil(retry_after_ms / 60_000))
    dngettext("errors", "1 minute", "%{count} minutes", minutes)
  end

  defp retry_after_wait(_retry_after_ms), do: dgettext("errors", "a moment")

  # Callers pass an email on the account-keyed buckets and an IP address or a
  # user id on the rest. Anything address-shaped is masked; an address that
  # will not parse is dropped rather than logged verbatim, so a malformed
  # value cannot slip through as "not an email".
  defp mask_identifier(identifier) when is_binary(identifier) do
    if String.contains?(identifier, "@") do
      SecurityLogger.mask_email(identifier) || "[REDACTED]"
    else
      identifier
    end
  end

  defp mask_identifier(identifier), do: identifier

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
