defmodule CredoChecks.ThinWrapperFunctions do
  @moduledoc """
  Detects thin wrapper functions that simply forward calls to already-aliased modules.

  Thin wrapper functions add unnecessary indirection and make code less transparent.
  Instead of creating private functions that just wrap module calls, use the
  aliased module directly.

  ## Bad

      # defp format_item(x), do: ItemFormatter.format_item(x)

  ## Good

      # Use ItemFormatter.format_item(x) directly at call sites

  A function with more than one clause is never flagged: its clauses dispatch
  between targets, so no single one of them is a wrapper. Clauses are matched
  by name alone, so a same-named function of another arity also exempts it.
  """

  use Credo.Check,
    base_priority: :low,
    category: :refactor,
    exit_status: 0,
    explanations: [
      check: """
      Detects thin wrapper functions that simply forward calls to already-aliased modules.

      Thin wrapper functions add unnecessary indirection and make code less transparent.
      Instead of creating private functions that just wrap module calls, use the
      aliased module directly.

      A function with more than one clause is never flagged, since its clauses
      dispatch between targets rather than forward to one.
      """,
      params: []
    ]

  alias Credo.IssueMeta
  alias Credo.SourceFile

  @doc false
  @impl Credo.Check
  @spec run(SourceFile.t(), any) :: list()
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    # Use line-based analysis for simplicity and reliability
    lines = SourceFile.lines(source_file)

    # Pattern to match thin wrapper functions
    thin_wrapper_regex = ~r/^\s*defp\s+(\w+)\([^)]*\),\s*do:\s*(\w+)\.(\w+)\(/
    multi_clause = multi_clause_names(lines)

    Enum.reduce(lines, [], &process_line(&1, &2, thin_wrapper_regex, multi_clause, issue_meta))
  end

  # Names of private functions defined by more than one clause
  defp multi_clause_names(lines) do
    lines
    |> Enum.flat_map(fn {_line_no, line} ->
      Regex.run(~r/^\s*defp\s+(\w+[?!]?)\(/, line, capture: :all_but_first) || []
    end)
    |> Enum.frequencies()
    |> Enum.flat_map(fn {name, count} -> if count > 1, do: [name], else: [] end)
    |> MapSet.new()
  end

  defp process_line({line_no, line}, issues, regex, multi_clause, issue_meta) do
    case Regex.run(regex, line, capture: :all_but_first) do
      [function_name, module_name, target_function] ->
        # Only flag a single-clause direct wrapper (same function name or obvious wrapper)
        if not MapSet.member?(multi_clause, function_name) and
             should_flag_as_wrapper?(function_name, target_function) do
          issue =
            issue_for(issue_meta, line_no, function_name, "#{module_name}.#{target_function}")

          [issue | issues]
        else
          issues
        end

      _other ->
        issues
    end
  end

  # Flag if function names are the same or it's an obvious wrapper pattern
  defp should_flag_as_wrapper?(function_name, target_function) do
    function_name == target_function or
      wrapper_pattern?(function_name, target_function)
  end

  # Common wrapper patterns
  defp wrapper_pattern?(function_name, target_function) do
    # Safe wrapper pattern: safe_decrypt -> decrypt
    (String.starts_with?(function_name, "safe_") and
       String.ends_with?(function_name, "_#{target_function}")) or
      function_name == "safe_#{target_function}"
  end

  defp issue_for(issue_meta, line_no, function_name, module_call) do
    format_issue(issue_meta,
      message:
        "Private function `#{function_name}` is a thin wrapper around `#{module_call}`. " <>
          "Consider calling `#{module_call}` directly instead.",
      line_no: line_no,
      trigger: function_name
    )
  end
end
