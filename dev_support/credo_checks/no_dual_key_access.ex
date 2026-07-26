defmodule CredoChecks.NoDualKeyAccess do
  @moduledoc """
  Flags reading the same map key both ways in one expression: `m[:key] ||
  m["key"]`.

  The pattern means the map's key type is unknown at the point of use, so
  every access site has to defend against both. That defence is easy to
  forget on the next access added, and the bug it produces (silently reading
  `nil` because the key was a string this time) is invisible until it
  reaches a user. Normalise once at the boundary that produced the map, then
  read it plainly everywhere else. `or` is matched the same way as `||`.

  ## Examples

      # Bad
      params[:email] || params["email"]
      attrs["name"] || attrs[:name]

      # Good — normalise at the boundary, then read one way
      params = normalize_keys(params)
      params[:email]

  Only `lib/` files are scanned; tests and migrations are excluded, since
  the intent is production diagnosability.
  """

  use Credo.Check,
    base_priority: :normal,
    category: :warning,
    explanations: [
      check: """
      Reading `m[:key] || m["key"]` spreads the question "which key type is
      this?" across every access site instead of answering it once where the
      map is built. Normalise the keys at the boundary and read them one way.
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

  defp traverse({op, meta, [left, right]} = ast, issues, issue_meta) when op in [:||, :or] do
    case dual_access(left, right) do
      nil -> {ast, issues}
      key -> {ast, [issue_for(issue_meta, meta, key) | issues]}
    end
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  # Both sides index the same subject, with keys that differ only in type.
  #
  # The subjects are compared as source text rather than as AST, because the
  # two occurrences carry different line/column metadata and so never compare
  # equal structurally.
  defp dual_access(left, right) do
    with {left_subject, left_key} <- access(left),
         {right_subject, right_key} <- access(right),
         true <- Macro.to_string(left_subject) == Macro.to_string(right_subject),
         true <- same_key_other_type?(left_key, right_key) do
      to_string(left_key)
    else
      _other -> nil
    end
  end

  defp access({{:., _dot_meta, [Access, :get]}, _meta, [subject, key]}), do: {subject, key}
  defp access(_ast), do: nil

  defp same_key_other_type?(key, key), do: false

  defp same_key_other_type?(left, right) when is_atom(left) and is_binary(right),
    do: Atom.to_string(left) == right

  defp same_key_other_type?(left, right) when is_binary(left) and is_atom(right),
    do: left == Atom.to_string(right)

  defp same_key_other_type?(_left, _right), do: false

  defp issue_for(issue_meta, meta, key) do
    format_issue(issue_meta,
      message:
        "Reading `#{key}` as both an atom and a string key. Normalise the map's keys " <>
          "at the boundary that builds it, then read them one way.",
      line_no: meta[:line],
      trigger: key
    )
  end
end
