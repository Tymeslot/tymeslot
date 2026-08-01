defmodule CredoChecks.ConnectionProbeBoundary do
  @moduledoc """
  Flags direct calls to a provider's `perform_connection_test/1` callback
  from outside its legitimate dispatchers.

  `perform_connection_test/1` is the calendar/video provider behaviour
  callback that actually reaches the network (see
  `Tymeslot.Integrations.Calendar.Provider` and
  `Tymeslot.Integrations.Video.Providers.ProviderBehaviour`). It is
  deliberately named differently from the human-facing `test_connection`
  API so a call straight to a provider module — skipping
  `Tymeslot.Integrations.Shared.ConnectionProbe`'s rate-limit metering
  entirely — reads as out-of-band and is easy to spot in review. This check
  makes that mechanical: `CredoChecks.RateLimiterBoundary` guards "don't
  meter outside the probe"; this one guards "don't probe outside the probe".

  ## Allowed call sites

  - `lib/tymeslot/integrations/calendar/connection.ex` — resolves the
    provider module and calls the callback from inside a `ConnectionProbe`
    request
  - `lib/tymeslot/integrations/video/providers/provider_registry.ex` —
    `test_provider_connection/2`, the one function `ProviderAdapter.test_connection/2`
    (itself called only from `Tymeslot.Integrations.Video.Connection`) uses
    to reach across the module boundary
  - Test files
  - An `:allowed` param (list of filename substrings), for any future caller
    with a genuine, reviewed reason to bypass `ConnectionProbe`:

        {CredoChecks.ConnectionProbeBoundary, [allowed: ["lib/tymeslot/some/exception.ex"]]}

  ## Examples

      # Bad — calling a provider's connection test directly from a LiveView
      defmodule MyAppWeb.SettingsComponent do
        def handle_event("test", _params, socket) do
          {:noreply, assign(socket, :result, SomeProvider.perform_connection_test(config))}
        end
      end

      # Good — go through the facade, which routes through ConnectionProbe
      defmodule MyAppWeb.SettingsComponent do
        def handle_event("test", _params, socket) do
          {:noreply, assign(socket, :result, Calendar.test_connection(integration))}
        end
      end
  """

  use Credo.Check,
    base_priority: :normal,
    category: :warning,
    param_defaults: [allowed: []],
    explanations: [
      check: """
      A provider's `perform_connection_test/1` callback must only be called
      from `Tymeslot.Integrations.Calendar.Connection` or
      `Tymeslot.Integrations.Video.Providers.ProviderRegistry` — every other
      caller belongs behind `Tymeslot.Integrations.Shared.ConnectionProbe`.
      """,
      params: [
        allowed: "List of filename substrings allowed to call the callback directly."
      ]
    ]

  alias Credo.Check.Params
  alias Credo.IssueMeta
  alias Credo.SourceFile

  @flagged_function :perform_connection_test
  @flagged_arity 1

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
    calendar_connection_file?(filename) or
      video_provider_registry_file?(filename) or
      test_file?(filename) or
      Enum.any?(allowed, &String.contains?(filename, &1))
  end

  defp calendar_connection_file?(filename),
    do: String.ends_with?(filename, "/integrations/calendar/connection.ex")

  defp video_provider_registry_file?(filename),
    do: String.ends_with?(filename, "/integrations/video/providers/provider_registry.ex")

  defp test_file?(filename) do
    String.contains?(filename, "/test/") or String.starts_with?(filename, "test/") or
      String.ends_with?(filename, "_test.exs")
  end

  # Match `x.perform_connection_test(config)` calls in the AST, regardless of
  # whether `x` is a module alias or a local variable — providers are
  # resolved dynamically (`provider_module.perform_connection_test(config)`),
  # so a plain alias match (as `RateLimiterBoundary` uses) would miss the
  # real call sites entirely.
  # AST shape: {{:., _, [lhs, func_name]}, meta, args}
  defp traverse({{:., _, [_lhs, func_name]}, meta, args} = ast, issues, issue_meta)
       when is_list(args) do
    if func_name == @flagged_function and length(args) == @flagged_arity do
      issue =
        format_issue(issue_meta,
          message:
            "`#{@flagged_function}/#{@flagged_arity}` should only be called through " <>
              "`Tymeslot.Integrations.Shared.ConnectionProbe` (via `Calendar.Connection` or " <>
              "`Video.Providers.ProviderRegistry`).",
          line_no: meta[:line],
          trigger: Atom.to_string(@flagged_function)
        )

      {ast, [issue | issues]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}
end
