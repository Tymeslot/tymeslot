defmodule CredoChecks.NoUnsafeSanitizeMerge do
  @moduledoc """
  Flags `Map.merge/2` calls that look like the unsafe sanitise-then-merge
  pattern: `Map.merge(params, sanitized)` where the second argument is a
  variable whose name starts with `sanitized` or is literally `selection`.

  The direct merge silently overwrites user-provided values with `nil` / `[]`
  sentinels returned for blank optional fields. Use
  `Tymeslot.Utils.SanitizeMerge.merge/2` instead, which preserves the
  user-provided value when the right-hand side is a drop-signal.

  ## Examples

      # Bad
      Map.merge(params, sanitized)
      Map.merge(params, sanitized_params)
      Map.merge(params, selection)

      # Good
      SanitizeMerge.merge(params, sanitized)
  """

  use Credo.Check,
    base_priority: :normal,
    category: :warning,
    explanations: [
      check: """
      `Map.merge(params, sanitized)` can clobber user input with drop-signal
      sentinels (`nil`, `[]`) returned by validators for blank optional
      fields. Use `Tymeslot.Utils.SanitizeMerge.merge/2` to preserve
      populated params entries in that case.
      """
    ]

  alias Credo.IssueMeta

  @flagged_names ["selection"]
  @flagged_prefix "sanitized"

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
    basename = Path.basename(filename)
    basename == "sanitize_merge.ex" or basename == "sanitize_merge_test.exs"
  end

  defp traverse(
         {{:., _call_meta, [{:__aliases__, _alias_meta, [:Map]}, :merge]}, meta, [_left, right]} =
           ast,
         issues,
         issue_meta
       ) do
    case flagged_variable_name(right) do
      nil ->
        {ast, issues}

      name ->
        issue =
          format_issue(issue_meta,
            message:
              "`Map.merge(params, #{name})` is unsafe — use " <>
                "`Tymeslot.Utils.SanitizeMerge.merge/2` instead.",
            line_no: meta[:line],
            trigger: "Map.merge"
          )

        {ast, [issue | issues]}
    end
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp flagged_variable_name({name, _meta, context}) when is_atom(name) and is_atom(context) do
    name_str = Atom.to_string(name)

    cond do
      name_str in @flagged_names -> name_str
      String.starts_with?(name_str, @flagged_prefix) -> name_str
      true -> nil
    end
  end

  defp flagged_variable_name(_other), do: nil
end
