defmodule Tymeslot.Integrations.Video.Connection do
  @moduledoc """
  Connection-related operations for video integrations.

  - Tests connection to providers
  - Emits telemetry for connection tests

  Provider-specific config shapes live in each provider module's `build_config/3`.
  """

  alias Tymeslot.Integrations.Shared.ConnectionProbe
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.ProviderConfig
  alias Tymeslot.Integrations.Video.Providers.ProviderAdapter
  alias Tymeslot.Integrations.Video.Providers.ProviderRegistry
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema

  @spec test_connection(pos_integer(), pos_integer()) :: {:ok, String.t()} | {:error, any()}
  def test_connection(user_id, id) when is_integer(user_id) and is_integer(id) do
    case Video.fetch_integration_for_user(id, user_id) do
      {:ok, integration} ->
        run_connection_test(integration)

      {:error, :not_found} = error ->
        error
    end
  end

  @doc """
  Runs a connection test against an already-loaded integration struct.

  Resolves the provider module from the single source of truth (`ProviderConfig`),
  builds the provider config via its `build_config/3` callback, and delegates to
  the provider's connection test. This is the one canonical connection-test path:
  the user-facing `test_connection/2` wraps it with loading and telemetry, and the
  background health check (`HealthCheck.Assessor`) calls it directly, so both
  exercise an identical pipeline and stay in lockstep as providers change.

  Also the single choke point for rate limiting: resolving the provider
  module, deciding the bucket it draws from, and (for a metered bucket)
  charging the right actor all happen once, inside `ConnectionProbe.probe/1`.
  `:scope` says which of the two callers is asking. It decides who a metered
  test is charged to, and keeping the two apart is the point: a busy
  instance's scheduled probing must never be able to exhaust the budget a
  real user's "Test connection" button draws from — and `:background` is
  unmetered by construction, per `ConnectionProbe`'s moduledoc.
  """
  @type scope :: ConnectionProbe.scope()

  @spec test_integration(VideoIntegrationSchema.t(), keyword()) ::
          {:ok, String.t()} | {:error, any()}
  def test_integration(%VideoIntegrationSchema{} = integration, opts \\ []) do
    scope = Keyword.get(opts, :scope, :interactive)

    with {:ok, provider_atom} <- ProviderConfig.parse_known(integration.provider),
         {:ok, provider_module} <- ProviderRegistry.get_provider(provider_atom) do
      decrypted = VideoIntegrationSchema.decrypt_credentials(integration)
      config = provider_module.build_config(integration, decrypted, [])

      ConnectionProbe.probe_provider(provider_module, integration,
        scope: scope,
        # Video's `config` is always freshly built by a caller, so it really
        # is untrusted input worth validating before a token is charged.
        validate: fn -> provider_module.validate_config(config) end,
        run: fn -> ProviderAdapter.test_connection(provider_atom, config) end
      )
    else
      _other -> {:error, :unsupported_provider}
    end
  end

  @doc """
  Runs the rate-limited connection probe for `provider_atom` against `config`,
  charging an already-resolved `actor` when the provider draws from a
  connection-test bucket (each provider's behaviour declares its own bucket
  via `connection_test_bucket/0`, with no default implementation, so a
  provider can't omit it). `validate_config/1` always runs first — for
  metered providers, before `actor` is charged a token — so a structurally
  invalid config never burns rate-limit budget. Routes the actual test
  through `ProviderAdapter.test_connection/2` so logging stays uniform
  across every caller.

  Unlike `test_integration/2`, there is no persisted integration to resolve
  an actor from here — `Video.do_create_integration/2` (the MiroTalk setup
  pre-check), the only caller, already knows who is submitting the form.

  Returns `ConnectionProbe`'s refusal tagged, never flattened to text —
  building copy for it is the caller's job (see the moduledoc on
  `Tymeslot.Integrations.Shared.ConnectionProbe`); `Video.do_create_integration/2`
  passes it straight up to its own caller.
  """
  @spec probe(atom(), map(), ConnectionProbe.actor()) :: {:ok, String.t()} | {:error, term()}
  def probe(provider_atom, config, actor) do
    case ProviderRegistry.get_provider(provider_atom) do
      {:ok, provider_module} ->
        ConnectionProbe.probe(%ConnectionProbe.Request{
          provider_module: provider_module,
          scope: :interactive,
          actor: actor,
          # Video's `config` is always freshly built by a caller, so it really
          # is untrusted input worth validating before a token is charged.
          validate: fn -> provider_module.validate_config(config) end,
          run: fn -> ProviderAdapter.test_connection(provider_atom, config) end
        })

      _other ->
        {:error, :unsupported_provider}
    end
  end

  defp run_connection_test(integration) do
    start_time = System.monotonic_time(:millisecond)
    result = test_integration(integration)

    :telemetry.execute(
      [:tymeslot, :integration, :test_connection],
      %{duration: System.monotonic_time(:millisecond) - start_time},
      %{provider: integration.provider, type: "video", success: match?({:ok, _}, result)}
    )

    result
  end
end
