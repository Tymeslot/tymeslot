defmodule CredoChecks.NoSwallowedException do
  @moduledoc """
  Flags `rescue` clauses that discard the exception without logging it or
  re-raising.

  A rescue that neither records nor re-raises turns a failure into a silent
  wrong answer. The external call that failed, the credential that expired,
  the malformed payload: all become an ordinary-looking `nil` or `:error`
  with nothing anywhere to say why. That is the failure mode hardest to
  diagnose in production, because there is no evidence it happened.

  A clause counts as handled if it logs (`Logger.*`), re-raises (`raise`,
  `reraise`, `Kernel.reraise`), exits, or **uses the bound exception** —
  passes it as an argument, interpolates it, or returns it — anywhere in the
  clause body. Passing the exception on to a helper (e.g.
  `handle_integration_error(error, provider)`) is genuine handling, not
  swallowing; discarding the binding entirely is the pattern this check
  targets.

  A clause bound to an unused name (`_error -> :ok`) is still flagged: the
  exception is never referenced anywhere, so there is no evidence it
  happened. That is a real, if occasionally intentional, residual class —
  see `Tymeslot.Infrastructure.CrashReporter`'s documented `_exception ->
  :ok` clause for an example that will keep reporting here on purpose.

  Only `lib/` files are scanned; tests and migrations are excluded, since
  the intent is production diagnosability.

  ## Examples

      # Bad
      rescue
        _error -> nil
      end

      # Good
      rescue
        error ->
          Logger.warning("Calendar sync failed", error: inspect(error))
          {:error, :sync_failed}
      end

      # Also good — the binding is used, even without a literal log/raise
      rescue
        error -> handle_integration_error(error, provider)
      end
  """

  use Credo.Check,
    base_priority: :normal,
    category: :warning,
    explanations: [
      check: """
      A `rescue` clause that neither logs nor re-raises turns a failure into
      a silent wrong answer, with no evidence left behind. Log the exception
      or re-raise it.
      """
    ]

  alias Credo.IssueMeta

  @handled [:raise, :reraise, :throw, :exit]
  @excluded_paths ["/test/", "/migrations/", "/deps/"]

  @doc false
  @impl Credo.Check
  @spec run(Credo.SourceFile.t(), keyword()) :: list()
  def run(%Credo.SourceFile{} = source_file, params) do
    if excluded?(source_file.filename) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
    end
  end

  defp excluded?(filename) do
    not lib_file?(filename) or Enum.any?(@excluded_paths, &String.contains?(filename, &1))
  end

  defp lib_file?(filename) do
    String.contains?(filename, "/lib/") or String.starts_with?(filename, "lib/")
  end

  defp traverse({:try, _meta, [blocks]} = ast, issues, issue_meta) when is_list(blocks) do
    {ast, rescue_issues(blocks, issues, issue_meta)}
  end

  # `def f do ... rescue ... end` desugars to the same keyword-block shape.
  defp traverse({:def, _meta, [_head, blocks]} = ast, issues, issue_meta) when is_list(blocks) do
    {ast, rescue_issues(blocks, issues, issue_meta)}
  end

  defp traverse({:defp, _meta, [_head, blocks]} = ast, issues, issue_meta) when is_list(blocks) do
    {ast, rescue_issues(blocks, issues, issue_meta)}
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp rescue_issues(blocks, issues, issue_meta) do
    blocks
    |> Keyword.get(:rescue, [])
    |> List.wrap()
    |> Enum.reduce(issues, fn clause, acc ->
      case unhandled_clause_line(clause) do
        nil -> acc
        line -> [issue_for(issue_meta, line) | acc]
      end
    end)
  end

  defp unhandled_clause_line({:->, meta, [pattern, body]}) do
    if handled?(pattern, body), do: nil, else: meta[:line]
  end

  defp unhandled_clause_line(_clause), do: nil

  defp handled?(pattern, body) do
    literal_handling?(body) or exception_referenced?(pattern, body)
  end

  defp literal_handling?(body) do
    {_ast, handled?} = Macro.prewalk(body, false, &detect_handling/2)
    handled?
  end

  defp detect_handling(node, true), do: {node, true}

  defp detect_handling({name, _meta, _args} = node, _acc) when name in @handled,
    do: {node, true}

  defp detect_handling(
         {{:., _dot, [{:__aliases__, _alias_meta, [:Logger]}, _fun]}, _m, _a} = node,
         _acc
       ),
       do: {node, true}

  # `Kernel.reraise/2,3` called as a remote call rather than the bare form.
  defp detect_handling(
         {{:., _dot, [{:__aliases__, _alias_meta, [:Kernel]}, :reraise]}, _m, _a} = node,
         _acc
       ),
       do: {node, true}

  defp detect_handling(node, acc), do: {node, acc}

  # The clause counts as handled when the pattern's bound exception is
  # referenced anywhere in the body — passed on, interpolated, or returned.
  # Discarding the binding entirely (never referencing it again) is what
  # "swallowed" means; a bound-but-unused name (`_error -> :ok`) still
  # counts as swallowed.
  defp exception_referenced?(pattern, body) do
    pattern
    |> bound_variable_names()
    |> Enum.any?(&variable_referenced?(body, &1))
  end

  defp bound_variable_names(pattern) do
    {_ast, names} =
      Macro.prewalk(pattern, [], fn
        {name, _meta, context} = node, acc when is_atom(name) and is_atom(context) ->
          {node, [name | acc]}

        node, acc ->
          {node, acc}
      end)

    names
  end

  defp variable_referenced?(body, name) do
    {_ast, referenced?} =
      Macro.prewalk(body, false, fn
        node, true ->
          {node, true}

        {^name, _meta, context} = node, _acc when is_atom(context) ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    referenced?
  end

  defp issue_for(issue_meta, line) do
    format_issue(issue_meta,
      message:
        "`rescue` clause neither logs the exception nor re-raises it, so the failure " <>
          "leaves no evidence. Log it or re-raise.",
      line_no: line,
      trigger: "rescue"
    )
  end
end
