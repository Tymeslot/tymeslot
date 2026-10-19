defmodule Tymeslot.Security.RateLimiter do
  @moduledoc """
  Rate limiting over `Tymeslot.Security.RateLimit`'s sliding log.

  Every named limit lives in `Tymeslot.Security.RateLimiter.Limits`, and
  `check/2` charges one of them:

      RateLimiter.check(:meeting_cancel, client_ip)
      RateLimiter.check(:webhook_write, user_id)

  A caller outside this application, which cannot add to that table, uses
  `check_bucket/2` with its own key and budget. Login and connection tests
  keep their own functions: one charges several related buckets and a
  failure-only throttle, the other picks its bucket from the provider.

  Every check answers `:ok` or `{:error, :rate_limited, message}`, where the
  message tells the person which limit stopped them and for how long. A
  `:user`-scoped limit given anything but a positive integer answers
  `{:error, :invalid_user_id}`, and an `:id`-scoped one `{:error, :invalid_id}`.
  """

  alias Tymeslot.Security.RateLimit
  alias Tymeslot.Security.RateLimiter.Auth
  alias Tymeslot.Security.RateLimiter.Helpers
  alias Tymeslot.Security.RateLimiter.Integrations
  alias Tymeslot.Security.RateLimiter.Limits

  @type bucket_key :: String.t()
  @type result :: :ok | {:error, :rate_limited, String.t()}

  @doc """
  Charges one hit against the named limit, for `key` (a client address, a
  user id, an email address or a prebuilt key, as the entry's scope says).
  Raises on a name that is not in `Limits`.
  """
  @spec check(Limits.name(), term()) ::
          result() | {:error, :invalid_user_id} | {:error, :invalid_id}
  def check(name, key) do
    entry = Limits.fetch!(name)

    with {:ok, suffix, identifier} <- scope_key(entry[:scope], key, entry[:operation]) do
      charge("#{entry[:prefix]}:#{suffix}", identifier, entry)
    end
  end

  @doc """
  Charges one hit against a bucket defined by the caller, for code outside
  this application that cannot add to `Limits`.

  Options: `:limit` and `:window_ms` (required, by name, so they cannot be
  swapped), `:operation` (required, the English name the log line carries),
  `:identifier` (what the log line names, masked when address-shaped),
  `:action` (the localised plural the refusal reads) and `log: false`.
  """
  @spec check_bucket(bucket_key(), keyword()) :: result()
  def check_bucket(bucket_key, opts) when is_binary(bucket_key) do
    Helpers.check_window(
      bucket_key,
      Keyword.fetch!(opts, :limit),
      Keyword.fetch!(opts, :window_ms),
      opts
    )
  end

  defp scope_key(:source, ip, _operation), do: {:ok, Helpers.source_key(ip), ip}

  defp scope_key(:user, user_id, _operation) when is_integer(user_id) and user_id > 0 do
    id = Integer.to_string(user_id)
    {:ok, id, id}
  end

  defp scope_key(:user, user_id, operation), do: Helpers.invalid_user_id(operation, user_id)

  defp scope_key(:id, id, _operation) when is_integer(id) and id > 0 do
    id = Integer.to_string(id)
    {:ok, id, id}
  end

  defp scope_key(:id, id, operation), do: Helpers.invalid_id(operation, id)

  defp scope_key(:email, email, _operation) when is_binary(email) do
    normalised = email |> String.trim() |> String.downcase()
    {:ok, normalised, normalised}
  end

  defp scope_key(:key, key, _operation) do
    key = to_string(key)
    {:ok, key, key}
  end

  defp charge(bucket_key, identifier, entry) do
    case entry[:tiers] do
      nil ->
        Helpers.check_window(bucket_key, entry[:limit], entry[:window_ms],
          operation: entry[:operation],
          identifier: identifier,
          action: action(entry),
          log: Keyword.get(entry, :log, true)
        )

      tiers ->
        Helpers.check_multi_bucket_limits(
          [{bucket_key, tiers, entry[:operation], action(entry)}],
          log: Keyword.get(entry, :log, true)
        )
    end
  end

  defp action(entry) do
    case entry[:action] do
      nil -> nil
      msgid -> Gettext.dgettext(TymeslotWeb.Gettext, "errors", msgid)
    end
  end

  @doc """
  Clear rate limit data for a specific bucket key.
  """
  @spec clear_bucket(bucket_key()) :: :ok
  defdelegate clear_bucket(bucket_key), to: Helpers

  @doc """
  Clear all rate limit data. Test-only.
  """
  @spec clear_all() :: :ok
  defdelegate clear_all, to: RateLimit

  @doc "The key a per-IP bucket counts as one client: IPv4 as it is, IPv6 by its /64."
  @spec source_key(nil | :inet.ip_address() | String.t()) :: String.t()
  defdelegate source_key(ip), to: Helpers

  # Auth

  @doc """
  Rate limit authentication attempts, including the failed-login throttle.

  The throttle and the per-account budget are keyed on the email *and* the
  client address, so failures from one address never lock the owner out from
  another; a wider per-email ceiling covers a run spread across many
  addresses. Returns :ok if allowed, {:error, :rate_limited, message} if
  exceeded.
  """
  @spec check_auth_rate_limit(String.t(), String.t() | nil) :: result()
  def check_auth_rate_limit(email, ip), do: Auth.check_auth(email, ip)

  @doc """
  Record an authentication attempt's result for the failed-login throttle,
  against the same email and client address `check_auth_rate_limit/2`
  consults. Returns `{:error, :account_throttled, message}` for the failure
  that crosses the threshold, and for every failure after it.
  """
  @spec record_auth_attempt(String.t(), String.t() | nil, boolean()) ::
          :ok | {:error, :account_throttled, String.t()}
  def record_auth_attempt(email, ip, success), do: Auth.record_attempt(email, ip, success)

  @doc """
  Rate limit sending a verification email: the requesting address's budget
  first, then the account's, so an address over its own limit spends nothing
  of the account's.
  """
  @spec check_verification_rate_limit(term(), String.t() | :inet.ip_address() | nil) :: result()
  def check_verification_rate_limit(user_id, ip) do
    with :ok <- check(:verification_ip, ip), do: check(:verification_user, user_id)
  end

  # Integrations

  @doc """
  Rate limit a provider's connection-test attempts, in the bucket the
  provider draws its budget from (`:caldav`, `:nextcloud`, `:mirotalk`,
  `:custom`, `:ics_url`, `:oauth`, or `:discovery` for calendar discovery,
  which is metered exactly like a connection test but isn't tied to any one
  provider's own bucket).

  Limit: 20 tests per 10 minutes per scope (30 for `:discovery`), except
  `:custom` and `:ics_url` — which probe an arbitrary user-supplied host — at
  5 per 10 minutes. The bucket is always charged to `{:user, user_id}` — an
  interactive "Test connection" click or integration setup. A scheduled
  background health probe never reaches this function at all: see
  `Tymeslot.Integrations.Shared.ConnectionProbe`'s `:background` clause
  (and its moduledoc) for why background probing is unmetered by
  construction rather than charged to some other bucket.

  `action` says what the person did to get here; see
  `t:Tymeslot.Security.RateLimiter.Integrations.connection_action/0`. It shapes
  the refusal they read, and defaults to `:connection_test`, the action the
  buckets are named after.

  Only `Tymeslot.Integrations.Shared.ConnectionProbe` calls this directly —
  `CredoChecks.RateLimiterBoundary` enforces that boundary mechanically.

  Returns :ok if allowed, {:error, :rate_limited, message} if exceeded.
  """
  @spec check_connection_test_rate_limit(
          Integrations.connection_bucket(),
          Integrations.connection_scope() | nil,
          Integrations.connection_action()
        ) :: result() | {:error, :unattributable}
  def check_connection_test_rate_limit(bucket, scope, action \\ :connection_test),
    do: Integrations.check_connection_test(bucket, scope, action)
end
