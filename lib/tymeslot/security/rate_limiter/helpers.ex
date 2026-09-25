defmodule Tymeslot.Security.RateLimiter.Helpers do
  @moduledoc false

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Security.RateLimit
  alias Tymeslot.Security.SecurityLogger

  @minute_ms 60_000
  @hour_minutes 60
  @day_minutes 24 * @hour_minutes

  @type bucket_key :: String.t()
  @type rate_check_result :: {:allow, pos_integer()} | {:deny, pos_integer()}

  @typedoc "One tier of a multi-bucket limit: its key suffix, its budget, and the window it spans."
  @type tier :: {String.t(), pos_integer(), pos_integer()}

  @typedoc """
  One bucket to charge: the key everything under it is prefixed with, its
  tiers ordered shortest window first, the English operation name the log line
  carries, and the localised label the refusal says out loud.
  """
  @type bucket :: {bucket_key(), [tier()], String.t(), String.t()}

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
        # Neither the identifier nor the bucket key reaches the log line raw:
        # the login and signup buckets are keyed on the email address, so a
        # rejection under attack would otherwise write it twice per request,
        # on the one path that fires at volume. `operation` already names the
        # bucket, so the bucket key adds nothing but the identifier.
        refuse(limit, window_ms, retry_after_ms, action || "#{operation} actions",
          operation: operation,
          identifier_masked: mask_identifier(identifier)
        )
    end
  end

  # The single refusal, shared by both paths, so the log line and the sentence
  # the person reads can never disagree about which limit stopped them.
  # `log_metadata` carries the English, searchable half; `action` carries the
  # localised half.
  defp refuse(limit, window_ms, retry_after_ms, action, log_metadata) do
    window_minutes = div(window_ms, @minute_ms)

    Logger.warning(
      "Rate limit exceeded",
      log_metadata ++
        [limit: limit, window_minutes: window_minutes, retry_after_ms: retry_after_ms]
    )

    {:error, :rate_limited, refusal_message(limit, window_ms, retry_after_ms, action)}
  end

  defp refusal_message(limit, window_ms, retry_after_ms, action) do
    dgettext(
      "errors",
      "You've reached the limit of %{limit} %{action} per %{window}. Please try again in %{wait}.",
      limit: limit,
      action: action,
      window: window_phrase(scale(window_ms)),
      wait: retry_after_wait(retry_after_ms)
    )
  end

  # The window is a phrase rather than a number of minutes in the sentence:
  # the multi-bucket tiers run from a single minute to a year, and "per 525600
  # minutes" is the kind of copy people notice. Each unit keeps its own plural
  # pair, whose singular omits the number, so the tightest tier reads "per
  # minute" rather than "per 1 minute".
  defp window_phrase({count, :minute}),
    do: dngettext("errors", "minute", "%{count} minutes", count)

  defp window_phrase({count, :hour}), do: dngettext("errors", "hour", "%{count} hours", count)
  defp window_phrase({count, :day}), do: dngettext("errors", "day", "%{count} days", count)

  # Hammer answers in milliseconds, and the wait rounds up rather than down:
  # telling someone to come back in "0 minutes" would send them straight into
  # a second refusal. Unlike the window, the singular carries its number,
  # since "try again in minute" is not a sentence.
  defp retry_after_wait(retry_after_ms) when is_integer(retry_after_ms) and retry_after_ms > 0 do
    wait_phrase(scale(retry_after_ms))
  end

  defp retry_after_wait(_retry_after_ms), do: dgettext("errors", "a moment")

  defp wait_phrase({count, :minute}),
    do: dngettext("errors", "1 minute", "%{count} minutes", count)

  defp wait_phrase({count, :hour}), do: dngettext("errors", "1 hour", "%{count} hours", count)
  defp wait_phrase({count, :day}), do: dngettext("errors", "1 day", "%{count} days", count)

  # The largest whole unit that spans the duration, rounding up within it so a
  # wait never reads shorter than it is and a second refusal cannot follow the
  # first. Days are the widest unit on purpose: a 30-day window is not a
  # calendar month and a 365-day one is not a year, and saying so would
  # misstate the limit.
  #
  # The unit is chosen from the rounded-up minutes rather than from the
  # milliseconds, so a wait Hammer reports a few milliseconds under the hour
  # still reads "1 hour" rather than "60 minutes".
  defp scale(ms), do: from_minutes(max(1, ceil(ms / @minute_ms)))

  defp from_minutes(minutes) when minutes >= @day_minutes,
    do: {ceil(minutes / @day_minutes), :day}

  defp from_minutes(minutes) when minutes >= @hour_minutes,
    do: {ceil(minutes / @hour_minutes), :hour}

  defp from_minutes(minutes), do: {minutes, :minute}

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

  @doc """
  Charges one token against every tier of every bucket, halting on the first
  refusal.

  Refuses in the same shape as `check_with_logging/6`, and for the same
  reason: a person who is over a limit needs to know which limit and for how
  long, not that something went wrong.
  """
  @spec check_multi_bucket_limits([bucket()]) :: :ok | {:error, :rate_limited, String.t()}
  def check_multi_bucket_limits(buckets) do
    Enum.reduce_while(buckets, :ok, fn {bucket_base, limits, operation, action}, _acc ->
      case apply_limits(bucket_base, limits, operation, action) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # The tiers are walked in list order and the walk halts on the first
  # refusal. They are ordered shortest window first, so the tier that halts
  # the walk is the tightest one that tripped, and its limit and window are
  # what the sentence names: telling someone about the daily cap when the
  # per-minute one stopped them would send them away for a day.
  @spec apply_limits(bucket_key(), [tier()], String.t(), String.t()) ::
          :ok | {:error, :rate_limited, String.t()}
  defp apply_limits(bucket_base, limits, operation, action) do
    Enum.reduce_while(limits, :ok, fn {label, limit, window_ms}, _acc ->
      case check_rate("#{bucket_base}:#{label}", window_ms, limit) do
        {:allow, _count} ->
          {:cont, :ok}

        {:deny, retry_after_ms} ->
          # No identifier here: these bucket bases embed one (an email address
          # on the signup, password-reset and booking-recipient buckets), so
          # the operation name is all that can go to the log line safely.
          {:halt, refuse(limit, window_ms, retry_after_ms, action, operation: operation)}
      end
    end)
  end
end
