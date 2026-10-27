defmodule Tymeslot.Security.RateLimiter.Helpers do
  @moduledoc false

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Security.RateLimit
  alias Tymeslot.Security.SecurityLogger

  @minute_ms 60_000
  @hour_minutes 60
  @day_minutes 24 * @hour_minutes

  @type bucket_key :: String.t()
  @type rate_check_result :: {:allow, non_neg_integer()} | {:deny, non_neg_integer()}

  @typedoc "One tier of a multi-bucket limit: its key suffix, its budget, and the window it spans."
  @type tier :: {String.t(), pos_integer(), pos_integer()}

  @typedoc """
  One bucket to charge: the key everything under it is prefixed with, its
  tiers ordered shortest window first, the English operation name the log line
  carries, and the localised label the refusal says out loud.
  """
  @type bucket :: {bucket_key(), [tier()], String.t(), String.t()}

  @spec check_rate(bucket_key(), pos_integer(), pos_integer()) :: rate_check_result()
  def check_rate(bucket_key, window_ms, limit), do: RateLimit.hit(bucket_key, window_ms, limit)

  @doc "How many hits a bucket holds inside its window, without charging it."
  @spec bucket_count(bucket_key(), pos_integer()) :: non_neg_integer()
  def bucket_count(bucket_key, window_ms), do: RateLimit.get(bucket_key, window_ms)

  @doc """
  Drops every hit a bucket holds.
  """
  @spec clear_bucket(bucket_key()) :: :ok
  defdelegate clear_bucket(bucket_key), to: RateLimit, as: :clear

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
    check_window(bucket_key, limit, window_ms,
      operation: operation,
      identifier: identifier,
      action: action
    )
  end

  @doc """
  `check_with_logging/6` with its labels as options, and one more: `log:
  false` refuses without the log line, for the flood caps on
  machine-to-machine endpoints, where a line per refused request would turn a
  flood into a log flood.
  """
  @spec check_window(bucket_key(), pos_integer(), pos_integer(), keyword()) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_window(bucket_key, limit, window_ms, opts)
      when is_integer(limit) and limit > 0 and is_integer(window_ms) and window_ms > 0 do
    operation = Keyword.fetch!(opts, :operation)
    action = Keyword.get(opts, :action) || "#{operation} actions"
    log? = Keyword.get(opts, :log, true)

    case check_rate(bucket_key, window_ms, limit) do
      {:allow, _count} ->
        :ok

      {:deny, retry_after_ms} when not log? ->
        {:error, :rate_limited, refusal_message(limit, window_ms, retry_after_ms, action)}

      {:deny, retry_after_ms} ->
        # Neither the identifier nor the bucket key reaches the log line raw:
        # the login and signup buckets are keyed on the email address, so a
        # rejection under attack would otherwise write it twice per request,
        # on the one path that fires at volume. `operation` already names the
        # bucket, so the bucket key adds nothing but the identifier.
        refuse(limit, window_ms, retry_after_ms, action,
          operation: operation,
          identifier_masked: mask_identifier(opts[:identifier])
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

  # The limiter answers in milliseconds, and the wait rounds up rather than down:
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
  # milliseconds, so a wait the limiter reports a few milliseconds under the hour
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
      user_id: LogFormat.reason(user_id)
    )

    {:error, :invalid_user_id}
  end

  @spec invalid_id(String.t(), any()) :: {:error, :invalid_id}
  def invalid_id(operation, id) do
    Logger.error("Invalid id for rate limit", operation: operation, id: LogFormat.reason(id))
    {:error, :invalid_id}
  end

  @doc """
  The key a per-IP bucket counts as one client.

  An IPv6 host is usually handed a whole /64 and can pick a fresh address
  from it for every request, so keying on the full address would give it an
  unlimited supply of fresh buckets; the /64 is what it actually controls,
  and is what the key names (`"2001:db8:1:2::/64"`). An IPv4-mapped IPv6
  address is keyed as the IPv4 address it carries, and IPv4 as it is.
  A missing address is `"unknown"`, and anything that does not parse is
  keyed as it came.

  Every per-IP bucket goes through this, so that no endpoint hands an IPv6
  client a wider budget than the one it is meant to.
  """
  @spec source_key(nil | :inet.ip_address() | String.t() | term()) :: String.t()
  def source_key(nil), do: "unknown"

  def source_key(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, address} -> address_key(address)
      {:error, _reason} -> ip
    end
  end

  def source_key(ip) when tuple_size(ip) in [4, 8] do
    if :inet.is_ip_address(ip), do: address_key(ip), else: inspect(ip)
  end

  def source_key(other), do: to_string(other)

  defp address_key({0, 0, 0, 0, 0, 0xFFFF, _hi, _lo} = mapped),
    do: mapped |> :inet.ipv4_mapped_ipv6_address() |> address_key()

  defp address_key({a, b, c, d, _e, _f, _g, _h}),
    do: ntoa({a, b, c, d, 0, 0, 0, 0}) <> "/64"

  defp address_key(ipv4), do: ntoa(ipv4)

  defp ntoa(address), do: address |> :inet.ntoa() |> to_string()

  @doc """
  Charges one token against every tier of every bucket, halting on the first
  refusal.

  Refuses in the same shape as `check_with_logging/6`, and for the same
  reason: a person who is over a limit needs to know which limit and for how
  long, not that something went wrong. `log: false` refuses without the log
  line, as `check_window/4` does.
  """
  @spec check_multi_bucket_limits([bucket()], keyword()) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_multi_bucket_limits(buckets, opts \\ []) do
    case first_refusal(buckets) do
      nil ->
        :ok

      refusal ->
        {limit, window_ms, operation, action, retry_after_ms} = binding_tier(buckets, refusal)

        if Keyword.get(opts, :log, true) do
          # No identifier here: these bucket bases embed one (an email address
          # on the signup, password-reset and booking-recipient buckets), so
          # the operation name is all that can go to the log line safely.
          refuse(limit, window_ms, retry_after_ms, action, operation: operation)
        else
          {:error, :rate_limited, refusal_message(limit, window_ms, retry_after_ms, action)}
        end
    end
  end

  # The tiers are walked in list order, shortest window first, and the walk
  # halts on the first refusal.
  defp first_refusal(buckets) do
    Enum.reduce_while(buckets, nil, fn {bucket_base, limits, operation, action}, nil ->
      case refusing_tier(bucket_base, limits) do
        nil -> {:cont, nil}
        {limit, window_ms} -> {:halt, {limit, window_ms, operation, action}}
      end
    end)
  end

  defp refusing_tier(bucket_base, limits) do
    Enum.reduce_while(limits, nil, fn {label, limit, window_ms}, nil ->
      case check_rate("#{bucket_base}:#{label}", window_ms, limit) do
        {:allow, _count} -> {:cont, nil}
        {:deny, _retry_after_ms} -> {:halt, {limit, window_ms}}
      end
    end)
  end

  # The refusal names the tier that binds: the one a retry has to wait
  # longest for, worked out without charging anything. A retry walks every
  # tier again, so the walk charged the tiers before the refusing one and the
  # ones after it may already be full; a wait timed by the refusing tier alone
  # could send someone straight into another refusal. Naming the binding
  # tier keeps the limit, window and wait in the sentence in agreement. On a
  # tie the shorter window speaks: sending somebody away for a day when a
  # minute would do is the failure that guards against. With nothing to wait
  # for (the bucket was cleared meanwhile), the refusing tier speaks.
  defp binding_tier(buckets, refusing) do
    waits =
      for {bucket_base, limits, operation, action} <- buckets,
          {label, limit, window_ms} <- limits do
        {RateLimit.retry_after("#{bucket_base}:#{label}", limit), -window_ms,
         {limit, window_ms, operation, action}}
      end

    case Enum.max_by(waits, fn {wait, shorter, _tier} -> {wait, shorter} end) do
      {0, _shorter, _tier} -> Tuple.insert_at(refusing, 4, 0)
      {wait, _shorter, tier} -> Tuple.insert_at(tier, 4, wait)
    end
  end
end
