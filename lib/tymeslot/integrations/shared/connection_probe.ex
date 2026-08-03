defmodule Tymeslot.Integrations.Shared.ConnectionProbe do
  @moduledoc """
  Single choke point for connection-test rate limiting.

  A "connection test" is any provider check that reaches out over the
  network to confirm credentials/reachability. Every caller that needs a
  rate-limited connection test — the dashboard's "Test connection" button,
  integration-creation pre-checks, and calendar discovery (folded in under
  the `:discovery` bucket) — builds a `Request` and calls `probe/1`, rather
  than calling the rate limiter directly. Providers themselves never call
  the rate limiter either: `probe/1` is the only place that does, and the
  `CredoChecks.RateLimiterBoundary` check enforces that mechanically.

  Every OAuth-backed and dev-only provider draws from a real bucket now
  (`:oauth` for OAuth providers, `:unmetered` only for dev-only demo/debug
  providers), so this module is the *only* place an interactive connection
  test can go unmetered — no compensating guard belongs anywhere else, web
  layer included.

  Each provider declares its own bucket via its behaviour's
  `connection_test_bucket/0` callback, rather than this module maintaining a
  table of provider -> bucket mappings: a provider that omits the callback
  fails compilation instead of silently running unmetered. `Request.bucket`
  overrides that lookup for a caller whose metering has nothing to do with
  any one provider's own bucket (calendar discovery draws from `:discovery`
  regardless of which CalDAV-family provider is being discovered against).

  ## Background probing is unmetered by construction

  `Request.scope: :background` (the scheduled health probe) skips metering
  entirely — no actor resolution, no bucket lookup, no rate-limiter call.
  This is a deliberate function-clause dispatch in `probe/1`, not a silent
  default: the scheduler already owns its own cadence (a 30-minute floor
  plus its own exponential backoff on failure), so a token bucket protects
  nothing there and only adds a way for the scheduler's own result to be
  corrupted by an unrelated refusal. `HealthCheck.orchestrate_health_check/2`
  additionally short-circuits on a `{:rate_limited, _}` refusal as
  belt-and-braces, in case a caller ever passes `scope: :background` through
  a path that still resolves a bucket.

  ## Error contract

  A refusal is always tagged, never flattened into free text: `{:error,
  {:rate_limited, message}}` carries the limiter's own user-facing message,
  `{:error, :unattributable}` means the caller could not resolve who to
  charge. Building copy for `:unattributable` is the *caller's* job — this
  module never invents user-facing text, so a caller with no web-facing
  consumer for the distinction is free to flatten it back down for its own
  purposes (see `Calendar.Connection.probe/3`, `Video.Connection.probe/3`).

  Both charge exactly one token, to exactly one actor, before running the
  provider's test — regardless of how many network calls that provider makes
  internally.

  Whatever validation a domain wants runs first and always unmetered, so a
  structurally invalid config never burns rate-limit budget. The two domains
  differ in what that means: Video always has a freshly-built config to
  check, whereas Calendar mostly probes already-persisted integrations,
  which must not be re-validated against current input rules (see
  `Calendar.Connection.test_connection/2`).
  """

  alias Tymeslot.Security.RateLimiter

  @typedoc "Who a connection test is charged to. Always required — never a shared bucket."
  @type actor :: {:user, pos_integer()}

  @typedoc """
  Who is asking for a connection test: `:interactive` (a user pressing "Test
  connection") or `:background` (a scheduled health probe). Keeping the two
  apart matters: an instance's scheduled probing must never be able to
  exhaust the budget a real user's button draws from, nor one user another's
  — and, per the moduledoc, `:background` is unmetered by construction.
  """
  @type scope :: :interactive | :background

  @typedoc """
  The connection-test bucket a provider draws its budget from. `:oauth`
  covers every OAuth-backed provider (its own token is already scarce, but
  a shared per-actor OAuth budget still protects the instance-wide OAuth
  quota every user draws from). `:discovery` covers calendar discovery,
  which is not tied to any single provider's own bucket. `:unmetered` is
  reserved for dev-only providers (demo/debug) whose test never reaches a
  real external service.
  """
  @type bucket ::
          :caldav | :nextcloud | :mirotalk | :custom | :ics_url | :oauth | :discovery | :unmetered

  @typedoc """
  Why `probe/1` refused to run the test. `{:rate_limited, message}` carries
  the limiter's own user-facing text; `:unattributable` means the caller's
  actor could not be resolved — deliberately atom-only, see the moduledoc.
  """
  @type refusal :: {:rate_limited, String.t()} | :unattributable

  @typedoc "What a connection test returns."
  @type result :: {:ok, String.t()} | {:error, refusal() | term()}

  defmodule Request do
    @moduledoc """
    One connection-test request, built by the caller and passed to
    `Tymeslot.Integrations.Shared.ConnectionProbe.probe/1`.

    `actor` must already be resolved by the caller — see
    `ConnectionProbe.resolve_actor/2` — never a raw subject/scope pair for
    this module to resolve internally. `bucket`, when given, overrides
    `provider_module.connection_test_bucket/0`; leave it `nil` to use the
    provider's own declared bucket. Neither field matters for a `:background`
    request: see the parent module's moduledoc on background metering.
    """

    @enforce_keys [:scope, :validate, :run]
    defstruct provider_module: nil,
              scope: nil,
              actor: nil,
              bucket: nil,
              validate: nil,
              run: nil

    @type t :: %__MODULE__{
            provider_module: module() | nil,
            scope: Tymeslot.Integrations.Shared.ConnectionProbe.scope(),
            actor: Tymeslot.Integrations.Shared.ConnectionProbe.actor() | nil,
            bucket: Tymeslot.Integrations.Shared.ConnectionProbe.bucket() | nil,
            validate: (-> :ok | {:error, term()}),
            run: (-> Tymeslot.Integrations.Shared.ConnectionProbe.result())
          }
  end

  @doc """
  Resolves the actor a connection test should be charged to.

  `subject` is the integration struct (or anything map-like carrying
  `:user_id` and `:id`) — never the provider-specific config a `Request.run`
  closure closes over, which can drop those fields entirely (see
  `Calendar.Connection.test_connection/2`). Callers only need this for
  `:interactive` requests; a `:background` request's actor is never charged
  (see the moduledoc), so a caller building one should pass `actor: nil`
  rather than call this.
  """
  @spec resolve_actor(map() | struct(), :interactive) ::
          {:ok, actor()} | {:error, :unattributable}
  def resolve_actor(subject, :interactive) do
    case Map.get(subject, :user_id) do
      user_id when is_integer(user_id) and user_id > 0 -> {:ok, {:user, user_id}}
      _other -> {:error, :unattributable}
    end
  end

  @doc """
  The whole connection-probe algorithm: validate, then (for an `:interactive`
  request) charge one token to `req.actor` in `req.bucket` — or the
  provider's own declared bucket, if `req.bucket` is `nil` — then run.

  A `:background` request skips the charge step entirely: see the moduledoc.

  `req.validate` runs before any token is charged. A caller with nothing to
  validate passes a function returning `:ok` — spelling that out at the call
  site keeps "this path deliberately does not validate" visible in code
  instead of buried in a moduledoc.

  `req.run` performs the actual I/O. It is a closure rather than a
  `{module, config}` pair because callers reach their provider differently:
  Calendar calls the provider module directly, Video routes through
  `ProviderAdapter` so its logging stays uniform, and discovery dispatches
  dynamically across the CalDAV-family provider modules.
  """
  @spec probe(Request.t()) :: result()
  def probe(%Request{scope: :background, validate: validate, run: run_fun})
      when is_function(validate, 0) and is_function(run_fun, 0) do
    with :ok <- validate.(), do: run_fun.()
  end

  def probe(%Request{scope: :interactive, validate: validate, run: run_fun} = req)
      when is_function(validate, 0) and is_function(run_fun, 0) do
    with :ok <- validate.() do
      case bucket_for(req) do
        :unmetered -> run_fun.()
        bucket -> with :ok <- check(bucket, req.actor), do: run_fun.()
      end
    end
  end

  @doc """
  Convenience wrapper around `probe/1` for a provider-backed request whose
  actor still needs resolving from a `subject` (an integration struct, or
  anything map-like carrying `:user_id` — see `resolve_actor/2`).

  Collapses the pattern every domain `Connection` module's `test_connection/2`
  (or `test_integration/2`) entry point used to repeat: resolve the actor —
  `nil` for a `:background` request, `nil` for an `:unmetered` provider
  bucket, otherwise `resolve_actor/2` — then build and run the `Request`.
  Not used by a caller that already has a resolved actor in hand (e.g. a
  creation pre-check submitting its own actor); those call `probe/1` directly.

  `opts`:
    * `:scope` — required, see `t:scope/0`
    * `:bucket` — optional, overrides `provider_module.connection_test_bucket/0`
    * `:validate` — required, a 0-arity function, see `Request.validate`
    * `:run` — required, a 0-arity function, see `Request.run`
  """
  @spec probe_provider(module(), map() | struct(), keyword()) :: result()
  def probe_provider(provider_module, subject, opts) do
    scope = Keyword.fetch!(opts, :scope)

    with {:ok, actor} <- resolve_probe_actor(provider_module, subject, scope) do
      probe(%Request{
        provider_module: provider_module,
        scope: scope,
        actor: actor,
        bucket: Keyword.get(opts, :bucket),
        validate: Keyword.fetch!(opts, :validate),
        run: Keyword.fetch!(opts, :run)
      })
    end
  end

  # `:background` never charges a token (see the moduledoc), so there is
  # nothing to resolve an actor from.
  defp resolve_probe_actor(_provider_module, _subject, :background), do: {:ok, nil}

  # An `:unmetered` provider (dev-only demo/debug) never needs one either —
  # `subject` isn't even guaranteed to carry a `user_id` for those (e.g. an
  # unpersisted `%{provider: "demo"}` probe config). Only a metered
  # `:interactive` probe actually resolves one.
  defp resolve_probe_actor(provider_module, subject, :interactive) do
    case provider_module.connection_test_bucket() do
      :unmetered -> {:ok, nil}
      _bucket -> resolve_actor(subject, :interactive)
    end
  end

  defp bucket_for(%Request{bucket: nil, provider_module: provider_module}),
    do: provider_module.connection_test_bucket()

  defp bucket_for(%Request{bucket: bucket}), do: bucket

  defp check(bucket, actor),
    do: to_error(RateLimiter.check_connection_test_rate_limit(bucket, actor))

  defp to_error(:ok), do: :ok
  defp to_error({:error, :rate_limited, message}), do: {:error, {:rate_limited, message}}
  defp to_error({:error, :unattributable}), do: {:error, :unattributable}
end
