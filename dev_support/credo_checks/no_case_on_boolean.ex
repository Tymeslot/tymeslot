defmodule CredoChecks.NoCaseOnBoolean do
  @moduledoc """
  Flags `case` expressions whose only clauses are `true` and `false`.

  A two-branch boolean `case` is an `if` written the long way, and it hides
  the third outcome: anything other than `true` or `false` raises
  `CaseClauseError` at a point far from the value's origin. `if/else` reads
  as what it is, and treats every non-boolean as falsey rather than crashing.

  Where the subject is a domain value rather than a boolean expression,
  prefer dispatching on shape in function heads, per the prefer/avoid table
  in CLAUDE.md.

  Only `lib/` files are scanned; tests and migrations are excluded, since
  the intent is production diagnosability.

  ## Examples

      # Bad
      case enabled? do
        true -> start()
        false -> :ok
      end

      # Good
      if enabled?, do: start(), else: :ok

      # Better, when the subject is a domain value
      def start_if_enabled(%{enabled: true}), do: start()
      def start_if_enabled(_settings), do: :ok
  """

  use Credo.Check,
    base_priority: :low,
    category: :refactor,
    explanations: [
      check: """
      A `case` with only `true` and `false` clauses is an `if` with extra
      punctuation, and it turns any non-boolean subject into a
      `CaseClauseError`. Use `if/else`, or dispatch on shape in function
      heads when the subject is a domain value.
      """
    ]

  alias Credo.IssueMeta

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

  defp traverse({:case, meta, [_subject, [do: clauses]]} = ast, issues, issue_meta)
       when is_list(clauses) do
    if boolean_only?(clauses) do
      {ast, [issue_for(issue_meta, meta) | issues]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  # Exactly two clauses, one matching `true` and one `false`, neither guarded.
  # A guard means the clause is doing more than dispatching on the boolean.
  defp boolean_only?([_first, _second] = clauses) do
    patterns = Enum.map(clauses, &clause_pattern/1)
    Enum.sort(patterns) == [false, true]
  end

  defp boolean_only?(_clauses), do: false

  defp clause_pattern({:->, _meta, [[pattern], _body]}) when is_boolean(pattern), do: pattern
  defp clause_pattern(_clause), do: nil

  defp issue_for(issue_meta, meta) do
    format_issue(issue_meta,
      message:
        "`case` with only `true`/`false` clauses. Use `if/else`, or dispatch on shape " <>
          "in function heads when the subject is a domain value.",
      line_no: meta[:line],
      trigger: "case"
    )
  end
end
