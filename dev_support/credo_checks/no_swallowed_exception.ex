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
  `reraise`), or exits. Returning a tagged error is fine as long as
  something is logged alongside it.

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

  @doc false
  @impl Credo.Check
  @spec run(Credo.SourceFile.t(), keyword()) :: list()
  def run(%Credo.SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
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

  defp unhandled_clause_line({:->, meta, [_pattern, body]}) do
    if handled?(body), do: nil, else: meta[:line]
  end

  defp unhandled_clause_line(_clause), do: nil

  defp handled?(body) do
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

  defp detect_handling(node, acc), do: {node, acc}

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
