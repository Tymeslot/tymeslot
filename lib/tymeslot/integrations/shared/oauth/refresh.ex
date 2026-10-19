defmodule Tymeslot.Integrations.Shared.OAuth.Refresh do
  @moduledoc """
  The one locked, double-checked OAuth token refresh, for calendar and video
  integrations alike.

  Under a blocking lock on the integration's key, `run/3`:

    1. re-reads the integration (`:fetch`), because another caller may have
       refreshed it while this one waited for the lock;
    2. hands back what the re-read row already holds when its token is still
       valid (`:already_valid`), without calling the token endpoint;
    3. otherwise refreshes from the re-read row (`:refresh`) and writes the
       result (`:persist`) before the lock is released.

  Persisting inside the lock is the point. A caller queued behind this one
  re-reads the row as soon as it gets the lock and must find the new expiry
  there, or it refreshes again: twice the load on the provider's rate limit,
  and with a provider that rotates refresh tokens (Microsoft, Zoom) the later
  write can keep the older one.

  The lock is held until the holder finishes or dies (`Shared.Lock` has no
  lease), so the wait is bounded by `:lock_timeout` and answered with
  `{:error, :lock_timeout}`.
  """

  alias Tymeslot.Clock
  alias Tymeslot.Integrations.Shared.Lock

  @buffer_seconds 300
  @default_lock_timeout_ms 60_000

  @type domain :: :calendar | :video
  @type lock_key :: {:oauth_token_refresh, domain(), term()}
  @type current :: term()
  @type result :: term()

  @typedoc """
  What the caller plugs into the flow. Each runs inside the lock.

    * `:fetch` — re-reads the integration: `{:ok, current}`, or `{:error, _}`
      to stop with that error. A caller that can still refresh when the row is
      gone answers with its own copy.
    * `:valid?` (optional) — whether `current` needs no refresh. Defaults to
      `valid?/2` on its `:token_expires_at` with the `:buffer_seconds` option.
    * `:already_valid` — the answer when `current` needs no refresh.
    * `:refresh` — calls the token endpoint with `current`'s credentials:
      `{:ok, refreshed}` or an error, which `run/3` returns as it is.
    * `:persist` (optional) — writes `refreshed` to the integration and gives
      the answer. Without it `run/3` answers `{:ok, refreshed}`, for a
      `:refresh` hook that persists by itself.
  """
  @type hooks :: %{
          required(:fetch) => (-> {:ok, current()} | {:error, term()}),
          optional(:valid?) => (current() -> boolean()),
          required(:already_valid) => (current() -> result()),
          required(:refresh) => (current() ->
                                   {:ok, term()} | {:error, term()} | {:error, atom(), term()}),
          optional(:persist) => (current(), term() -> result())
        }

  @doc """
  The lock key for an integration's token refresh. One key per integration,
  whichever path refreshes it (a scheduled job, a connection test, an API call
  finding its token expired), and namespaced by domain because calendar and
  video integrations live in different tables with overlapping ids.
  """
  @spec lock_key(domain(), term()) :: lock_key()
  def lock_key(domain, integration_id) when domain in [:calendar, :video],
    do: {:oauth_token_refresh, domain, integration_id}

  @doc """
  Whether a token expiring at `expires_at` is good for more than
  `buffer_seconds` yet (5 minutes by default). An unknown expiry is not valid:
  a token whose lifetime nobody recorded is refreshed rather than trusted.
  """
  @spec valid?(DateTime.t() | nil, non_neg_integer()) :: boolean()
  def valid?(expires_at, buffer_seconds \\ @buffer_seconds)
  def valid?(nil, _buffer_seconds), do: false

  def valid?(%DateTime{} = expires_at, buffer_seconds) do
    DateTime.compare(expires_at, DateTime.add(Clock.utc_now(), buffer_seconds, :second)) == :gt
  end

  @doc """
  Runs the locked, double-checked refresh. See the module docs.

  ## Options

    * `:buffer_seconds` — the validity buffer for the default `:valid?`
      (5 minutes).
    * `:lock_timeout` — how long to wait for the lock, in milliseconds
      (60 seconds).
  """
  @spec run(lock_key(), hooks(), keyword()) :: result() | {:error, :lock_timeout}
  def run(key, hooks, opts \\ []) do
    buffer_seconds = Keyword.get(opts, :buffer_seconds, @buffer_seconds)
    valid? = Map.get(hooks, :valid?, &valid?(Map.get(&1, :token_expires_at), buffer_seconds))

    Lock.with_lock(key, fn -> under_lock(hooks, valid?) end,
      mode: :blocking,
      timeout: Keyword.get(opts, :lock_timeout, @default_lock_timeout_ms)
    )
  end

  defp under_lock(hooks, valid?) do
    with {:ok, current} <- hooks.fetch.() do
      if valid?.(current) do
        hooks.already_valid.(current)
      else
        refresh_and_persist(hooks, current)
      end
    end
  end

  defp refresh_and_persist(hooks, current) do
    case hooks.refresh.(current) do
      {:ok, refreshed} ->
        case Map.fetch(hooks, :persist) do
          {:ok, persist} -> persist.(current, refreshed)
          :error -> {:ok, refreshed}
        end

      error ->
        error
    end
  end
end
