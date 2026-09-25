defmodule CredoChecks.TestGlobalStateRequiresSync do
  @moduledoc """
  Ensures a test module that mutates node-wide runtime state declares
  `async: false`. The sibling of `CredoChecks.TestGlobalConfigRequiresSync`,
  for the two other node-wide mutations in this test suite besides
  application env.

  `test/support/log_capture.ex`'s moduledoc states the rule this check
  enforces, verbatim:

  > A `:logger` handler is global: it sees events from every process, so a
  > handler attached by one test also receives whatever concurrently running
  > async tests log. [...] A module that lowers the primary Logger level
  > (`:logger_level`) or asserts on the *absence* of a log
  > (`refute_receive {:captured_log, _}`) must be `async: false`; neither is
  > safe to run alongside other tests.

  Mox's global mode has the identical shape: `Mox.set_mox_global/0,1`
  switches every process on the node to see the same expectations, not just
  the calling test's own, so a concurrent async test can steal or supply an
  expectation that was never meant for it.

  A module doing either while `async: true` corrupts whichever unrelated
  test happens to run beside it, so the failure surfaces only in a full run
  and passes in isolation — the same signature `TestGlobalConfigRequiresSync`
  exists to catch for `Application.put_env/3`.

  ## What is flagged

  A module whose name ends in `Test`, declaring `async: true`, that does any
  of the following, directly or through a case template it `use`s or
  `import`s:

    * Puts Mox into global mode: `setup :set_mox_global`, a bare
      `set_mox_global()` call, or `Mox.set_mox_global(...)`.
    * Lowers the primary Logger level through the project's capture helper:
      a call to `Tymeslot.Test.LogCapture.attach/1` or `.with_capture/2` whose
      options contain a `:logger_level` key.
    * Asserts the *absence* of a log: `refute_receive` or `refute_received`
      whose pattern mentions `:captured_log`.
    * Adds or removes a `:logger` handler: `:logger.add_handler/3` or
      `:logger.remove_handler/1`. `:logger`'s server computes the handler list
      for a removal when the request arrives but writes it back later, so a
      removal racing another process's add or remove can drop a handler from
      the list or list one twice. `ExUnit.CaptureServer` adds and removes its
      handler throughout every run, so an async module doing the same corrupts
      `capture_log` for the rest of the suite. `Tymeslot.Test.LogCapture`
      explains the race.

  ## The deliberate carve-out

  A module that calls `LogCapture.attach()` with **no** options, and only
  asserts a log's *presence* (`assert_receive {:captured_log, _}`), is safe
  and stays `async: true`. Attaching adds no `:logger` handler (the one
  handler is installed once for the suite) and only registers the calling
  process; only lowering the primary level or asserting on absence reaches
  outside the calling test.

  ## Inheriting through a case template

  Credo analyses one file at a time and cannot follow `use` or `import`, so
  the offending module's own source can look completely inert. Two templates
  under `test/support/` currently put Mox into global mode from their own
  `setup`, and are the check's default `:templates` param:

    * `TymeslotWeb.BrowserCase` — Wallaby drives the app from a separate OS
      process, so Mox expectations must be visible to it.
    * `Tymeslot.Integrations.HealthCheckTestSetup` — `HealthCheck` dispatches
      across Oban workers and GenServer calls that may cross process
      boundaries.

  A module reaches either through `use` (`BrowserCase` is an
  `ExUnit.CaseTemplate`) or through `import` plus a `setup :fun_name` call
  (`HealthCheckTestSetup` is a plain module of shared setup helpers, not a
  template). This check treats both as adoption of the template: it cannot
  see which imported function a `setup :atom` actually names, so importing
  one of the listed modules is itself the signal.

  ## Opting out

  A module with no concurrent reader of the affected state cannot be
  corrupted, and serialising it buys nothing. Mark it with a comment on the
  line above the `use`:

      # credo:global-state-safe — <why no concurrent reader exists>

  State the reason. "Nothing else reads this" is checkable by the next
  person; a bare opt-out is not.

  ## Examples

      # Bad — global Mox mode while running concurrently
      defmodule MyApp.HealthCheckTest do
        use MyApp.DataCase, async: true

        setup :set_mox_global
      end

      # Bad — inherits global Mox mode from the template, and looks inert doing it
      defmodule MyApp.LoginFlowTest do
        use MyAppWeb.BrowserCase, async: true
      end

      # Bad — lowers the primary Logger level while running concurrently
      defmodule MyApp.AuditLogTest do
        use MyApp.DataCase, async: true

        test "logs the failed attempt" do
          LogCapture.attach(logger_level: :debug)
          ...
        end
      end

      # Bad — asserts the absence of a log while running concurrently
      defmodule MyApp.QuietPathTest do
        use MyApp.DataCase, async: true

        test "does not log on the happy path" do
          LogCapture.attach()
          ...
          refute_receive {:captured_log, _}, 100
        end
      end

      # Good — serialised, so the mutation cannot reach a concurrent test
      defmodule MyApp.HealthCheckTest do
        use MyApp.DataCase, async: false

        setup :set_mox_global
      end

      # Good — presence-only assertion, still safe to run concurrently
      defmodule MyApp.AuditLogTest do
        use MyApp.DataCase, async: true

        test "logs the failed attempt" do
          LogCapture.attach()
          ...
          assert_receive {:captured_log, %{level: :warning}}
        end
      end

      # Good — opted out, with the reason recorded
      defmodule MyApp.ExtensionMoxTest do
        # credo:global-state-safe — this is the only test that stubs Extension
        use MyApp.DataCase, async: true

        setup :set_mox_global
      end
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      A test module that mutates node-wide runtime state must declare
      async: false.

      Mox global mode, lowering the primary Logger level, asserting on the
      absence of a log, and adding or removing a :logger handler all reach
      past the calling test's own process: an
      async module doing any of them corrupts every test running alongside
      it. The failure surfaces in an unrelated module and only in a full run.

      Mutation is inherited through case templates too; those are listed in
      the :templates param.

      Opt out with `# credo:global-state-safe — <reason>` above the `use`
      when no concurrent reader of the affected state exists.
      """,
      params: [
        templates:
          "Override the modules treated as putting Mox into global mode from their " <>
            "own setup, whether adopted via use or import. Defaults to " <>
            "[TymeslotWeb.BrowserCase, Tymeslot.Integrations.HealthCheckTestSetup]."
      ]
    ]

  alias Credo.Code
  alias Credo.IssueMeta

  @opt_out "credo:global-state-safe"

  @default_templates [
    TymeslotWeb.BrowserCase,
    Tymeslot.Integrations.HealthCheckTestSetup
  ]

  @doc false
  @impl Credo.Check
  @spec run(Credo.SourceFile.t(), keyword()) :: list()
  def run(%Credo.SourceFile{} = source_file, params) do
    if test_file?(source_file.filename) and not opted_out?(source_file) do
      issue_meta = IssueMeta.for(source_file, params)
      templates = Keyword.get(params, :templates, @default_templates)

      Code.prewalk(source_file, &traverse(&1, &2, issue_meta, templates))
    else
      []
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Read from the raw source rather than the AST: Elixir discards comments
  # when parsing, so an opt-out marker exists nowhere in the quoted form.
  defp opted_out?(source_file) do
    source_file |> Code.to_lines() |> Enum.any?(fn {_no, line} -> line =~ @opt_out end)
  end

  # Credo reports repo-relative filenames, so match on the path segment
  # rather than searching for "/test/" in the string.
  defp test_file?(filename) do
    segments = Path.split(filename)

    String.ends_with?(filename, "_test.exs") and
      "test" in segments and
      not support_file?(segments)
  end

  defp support_file?(segments) do
    segments
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(&(&1 == ["test", "support"]))
  end

  defp traverse(
         {:defmodule, meta, [name, [do: {:__block__, _meta, body}]]} = ast,
         issues,
         issue_meta,
         templates
       ) do
    check_module(ast, name, meta[:line], body, issues, issue_meta, templates)
  end

  defp traverse(
         {:defmodule, meta, [name, [do: single_expr]]} = ast,
         issues,
         issue_meta,
         templates
       )
       when not is_list(single_expr) do
    check_module(ast, name, meta[:line], [single_expr], issues, issue_meta, templates)
  end

  defp traverse(ast, issues, _issue_meta, _templates), do: {ast, issues}

  defp check_module(ast, name, line_no, body, issues, issue_meta, templates) do
    with true <- test_module?(name),
         true <- async?(body),
         {:ok, reason} <- mutates_global_state(body, templates) do
      {ast, [build_issue(issue_meta, line_no, reason) | issues]}
    else
      _no_issue -> {ast, issues}
    end
  end

  # Only modules whose last name segment ends in "Test": inline helper and
  # mock modules defined inside a test file are not test modules.
  defp test_module?({:__aliases__, _, segments}) when is_list(segments) do
    case List.last(segments) do
      name when is_atom(name) -> name |> to_string() |> String.ends_with?("Test")
      _other -> false
    end
  end

  defp test_module?(_name), do: false

  # A module is concurrent only if it says so. async: defaults to false in
  # every case template here, so an absent option is not a finding.
  defp async?(body) do
    Enum.any?(body, fn
      {:use, _meta, [_template, opts]} when is_list(opts) -> Keyword.get(opts, :async) == true
      _other -> false
    end)
  end

  defp mutates_global_state(body, templates) do
    cond do
      template = used_template(body, templates) -> {:ok, {:template, template}}
      call = mox_global_call(body) -> {:ok, {:mox_global, call}}
      call = lowered_log_level_call(body) -> {:ok, {:log_capture, call}}
      macro = refute_absence_call(body) -> {:ok, {:refute_absence, macro}}
      call = logger_handler_call(body) -> {:ok, {:logger_handler, call}}
      true -> :none
    end
  end

  # A template is adopted either as a real case template (`use`) or as a
  # shared setup module (`import` + a `setup :fun_name` this check cannot
  # trace back to its source). Either form is the signal: it is not possible
  # to tell, from this file alone, whether an imported setup function was
  # actually wired up — so importing the module is treated the same as using
  # it, matching how CredoChecks.TestGlobalConfigRequiresSync treats `use`.
  defp used_template(body, templates) do
    Enum.find_value(body, fn
      {kind, _meta, [{:__aliases__, _am, segments} | _opts]} when kind in [:use, :import] ->
        module = Module.concat(segments)
        if module in templates, do: module

      _other ->
        nil
    end)
  end

  # Walks the whole module body: the mutating call is usually inside a
  # `setup` block or a single test, never at the top level.
  defp mox_global_call(body) do
    {_ast, found} =
      Macro.prewalk(body, nil, fn
        {:setup, _meta, [:set_mox_global]} = node, nil ->
          {node, "setup :set_mox_global"}

        {:set_mox_global, _meta, []} = node, nil ->
          {node, "set_mox_global()"}

        {{:., _dot, [{:__aliases__, _am, [:Mox]}, :set_mox_global]}, _meta, _args} = node, nil ->
          {node, "Mox.set_mox_global"}

        node, acc ->
          {node, acc}
      end)

    found
  end

  @log_capture_functions [:attach, :with_capture]

  defp lowered_log_level_call(body) do
    {_ast, found} =
      Macro.prewalk(body, nil, fn
        {{:., _dot, [{:__aliases__, _am, segments}, fun]}, _meta, args} = node, nil
        when fun in @log_capture_functions ->
          if log_capture_module?(segments) and logger_level_opt?(args) do
            {node, "LogCapture.#{fun}"}
          else
            {node, nil}
          end

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp log_capture_module?(segments), do: List.last(segments) == :LogCapture

  # Only the first argument carries the options (`attach(opts)`,
  # `with_capture(opts, fun)`), so the walk is scoped to it. Walking the whole
  # argument list would also walk `with_capture`'s closure body, where an
  # unrelated `logger_level:` key (in an assertion, say) would read as evidence
  # that the primary level was lowered. A first argument that is not a literal
  # list is either the closure of `with_capture(fun)` or a variable, neither of
  # which states a level here.
  defp logger_level_opt?([opts | _rest]) when is_list(opts) do
    {_ast, found} =
      Macro.prewalk(opts, false, fn
        {:logger_level, _value} = node, false -> {node, true}
        node, acc -> {node, acc}
      end)

    found
  end

  defp logger_level_opt?(_args), do: false

  @refute_macros [:refute_receive, :refute_received]

  defp refute_absence_call(body) do
    {_ast, found} =
      Macro.prewalk(body, nil, fn
        {macro, _meta, args} = node, nil when macro in @refute_macros and is_list(args) ->
          if captured_log_pattern?(args), do: {node, "#{macro}"}, else: {node, nil}

        node, acc ->
          {node, acc}
      end)

    found
  end

  @logger_handler_functions [:add_handler, :remove_handler]

  defp logger_handler_call(body) do
    {_ast, found} =
      Macro.prewalk(body, nil, fn
        {{:., _dot, [:logger, fun]}, _meta, _args} = node, nil
        when fun in @logger_handler_functions ->
          {node, ":logger.#{fun}"}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp captured_log_pattern?(args) do
    {_ast, found} =
      Macro.prewalk(args, false, fn
        :captured_log = node, false -> {node, true}
        node, acc -> {node, acc}
      end)

    found
  end

  defp build_issue(issue_meta, line_no, {:template, template}) do
    format_issue(issue_meta,
      message:
        "Test module is async: true but uses or imports #{inspect(template)}, whose setup " <>
          "puts Mox into global mode — expectations become visible to every process on the " <>
          "node, not just this test's own. Declare async: false, or opt out with " <>
          "`# credo:global-state-safe — <reason>`.",
      line_no: line_no,
      trigger: "async: true"
    )
  end

  defp build_issue(issue_meta, line_no, {:mox_global, call}) do
    format_issue(issue_meta,
      message:
        "Test module is async: true and calls #{call}, which puts Mox into global mode — " <>
          "expectations become visible to every process on the node, not just this test's " <>
          "own. Declare async: false, or opt out with `# credo:global-state-safe — <reason>`.",
      line_no: line_no,
      trigger: "async: true"
    )
  end

  defp build_issue(issue_meta, line_no, {:log_capture, call}) do
    format_issue(issue_meta,
      message:
        "Test module is async: true and calls #{call} with :logger_level, which lowers the " <>
          "primary Logger level for the whole node while it runs. Declare async: false, or " <>
          "opt out with `# credo:global-state-safe — <reason>`.",
      line_no: line_no,
      trigger: "async: true"
    )
  end

  defp build_issue(issue_meta, line_no, {:refute_absence, macro}) do
    format_issue(issue_meta,
      message:
        "Test module is async: true and asserts the absence of a log with #{macro}, but the " <>
          ":logger handler is global — a concurrent test's log can satisfy or defeat the " <>
          "assertion. Declare async: false, or opt out with " <>
          "`# credo:global-state-safe — <reason>`.",
      line_no: line_no,
      trigger: "async: true"
    )
  end

  defp build_issue(issue_meta, line_no, {:logger_handler, call}) do
    format_issue(issue_meta,
      message:
        "Test module is async: true and calls #{call}. Adding or removing a :logger handler " <>
          "while other tests run can list ExUnit's capture handler twice, doubling every " <>
          "captured log line for the rest of the suite. Use Tymeslot.Test.LogCapture, declare " <>
          "async: false, or opt out with `# credo:global-state-safe — <reason>`.",
      line_no: line_no,
      trigger: "async: true"
    )
  end
end
