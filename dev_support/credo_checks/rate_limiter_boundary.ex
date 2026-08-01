defmodule CredoChecks.RateLimiterBoundary do
  @moduledoc """
  Flags direct calls to `RateLimiter.check_connection_test_rate_limit/2` from
  outside its one legitimate caller.

  `Tymeslot.Integrations.Shared.ConnectionProbe` is the single choke point
  for connection-test rate limiting — every metered "Test connection" click,
  integration-creation pre-check, and calendar discovery request (folded in
  under the `:discovery` bucket) goes through it. A caller that reaches past
  `ConnectionProbe` to call the limiter directly reintroduces the bug this
  boundary exists to prevent: a second, uncoordinated place a connection
  test can go unmetered.

  ## Scoping decision

  Only `check_connection_test_rate_limit/2` is flagged, not every
  `Tymeslot.Security.RateLimiter.*` function. The web layer has legitimate,
  non-connection-test rate limiting of its own (e.g.
  `check_integration_write_rate_limit/1` in dashboard LiveComponents), and
  flagging the whole module would either produce false positives on those or
  force a broad allowlist that swallows real violations alongside them.
  Scoping to the one function this boundary is actually about — the
  connection-test API — keeps the check meaningful.

  ## Allowed call sites

  - `lib/tymeslot/integrations/shared/connection_probe.ex` — the choke point
    itself
  - Files under `lib/tymeslot/security/` — `RateLimiter`'s own
    implementation modules
  - Test files
  - An `:allowed` param (list of filename substrings), for any future caller
    with a genuine, reviewed reason to bypass `ConnectionProbe`:

        {CredoChecks.RateLimiterBoundary, [allowed: ["lib/tymeslot/some/exception.ex"]]}

  ## Examples

      # Bad — calling the limiter directly from a context module
      defmodule MyApp.Integrations do
        def test(bucket, actor), do: RateLimiter.check_connection_test_rate_limit(bucket, actor)
      end

      # Good — go through ConnectionProbe
      defmodule MyApp.Integrations do
        def test(provider_module, actor, validate, run) do
          ConnectionProbe.probe(%ConnectionProbe.Request{
            provider_module: provider_module,
            scope: :interactive,
            actor: actor,
            validate: validate,
            run: run
          })
        end
      end
  """

  use Credo.Check,
    base_priority: :normal,
    category: :warning,
    param_defaults: [allowed: []],
    explanations: [
      check: """
      Connection-test rate limiting must go through
      `Tymeslot.Integrations.Shared.ConnectionProbe`, not
      `RateLimiter.check_connection_test_rate_limit/2` directly.
      """,
      params: [
        allowed: "List of filename substrings allowed to call the limiter directly."
      ]
    ]

  alias Credo.Check.Params
  alias Credo.IssueMeta
  alias Credo.SourceFile

  @flagged_function :check_connection_test_rate_limit
  @flagged_arity 2

  @doc false
  @impl Credo.Check
  @spec run(SourceFile.t(), keyword()) :: list()
  def run(%SourceFile{} = source_file, params) do
    filename = source_file.filename
    allowed = Params.get(params, :allowed, __MODULE__)

    if excluded?(filename, allowed) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
    end
  end

  defp excluded?(filename, allowed) do
    connection_probe_file?(filename) or
      security_file?(filename) or
      test_file?(filename) or
      Enum.any?(allowed, &String.contains?(filename, &1))
  end

  defp connection_probe_file?(filename),
    do: String.ends_with?(filename, "/integrations/shared/connection_probe.ex")

  defp security_file?(filename) do
    String.contains?(filename, "/security/") or String.starts_with?(filename, "security/")
  end

  defp test_file?(filename) do
    String.contains?(filename, "/test/") or String.starts_with?(filename, "test/") or
      String.ends_with?(filename, "_test.exs")
  end

  # Match Module.function(args) calls in the AST.
  # AST shape: {{:., _, [{:__aliases__, _, aliases}, func_name]}, meta, args}
  defp traverse(
         {{:., _, [{:__aliases__, _, aliases}, func_name]}, meta, args} = ast,
         issues,
         issue_meta
       )
       when is_list(aliases) and is_list(args) do
    if func_name == @flagged_function and length(args) == @flagged_arity and
         rate_limiter_reference?(aliases) do
      module_prefix = aliases |> Enum.map(&Atom.to_string/1) |> Enum.join(".")
      trigger = "#{module_prefix}.#{func_name}"

      issue =
        format_issue(issue_meta,
          message:
            "`#{trigger}/#{@flagged_arity}` should only be called through " <>
              "`Tymeslot.Integrations.Shared.ConnectionProbe`.",
          line_no: meta[:line],
          trigger: trigger
        )

      {ast, [issue | issues]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  # A call is a `RateLimiter` reference when the module alias's last segment
  # is `RateLimiter` — matches both the aliased short form (`RateLimiter.foo`)
  # and the fully qualified name (`Tymeslot.Security.RateLimiter.foo`).
  defp rate_limiter_reference?(aliases) do
    case List.last(aliases) do
      :RateLimiter -> true
      _other -> false
    end
  end
end
