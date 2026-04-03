defmodule CredoChecks.TestModuleTagRequired do
  @moduledoc """
  Ensures every test module declares at least one `@moduletag` from the approved taxonomy.

  Tags enable targeted test runs, CI filtering, and organised test reporting. A module
  without a recognised tag cannot be filtered by domain or type, making it harder to
  run scoped suites (e.g. `mix test --only auth`).

  The allowed tag list is maintained in `Tymeslot.Test.TagTaxonomy` (in `test/support/`) —
  that module is the single source of truth for the taxonomy. Edit it there to add or rename tags.

  ## Examples

      # Bad — no @moduletag at all
      defmodule MyApp.AuthTest do
        use MyApp.DataCase, async: true
        # ...
      end

      # Bad — unrecognised tag not in the taxonomy
      defmodule MyApp.AuthTest do
        use MyApp.DataCase, async: true
        @moduletag :my_custom_thing
        # ...
      end

      # Good — tagged with an approved domain tag
      defmodule MyApp.AuthTest do
        use MyApp.DataCase, async: true
        @moduletag :auth
        # ...
      end

      # Good — keyword-style tag (key must be in the taxonomy)
      defmodule MyApp.AuthTest do
        use MyApp.DataCase, async: true
        @moduletag backup_tests: true
        # ...
      end
  """

  use Credo.Check,
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      Every test module must declare at least one @moduletag from the approved taxonomy.

      Tags enable targeted test runs, CI filtering, and organised reporting.
      The taxonomy lives in Tymeslot.Test.TagTaxonomy (test/support/tag_taxonomy.ex).
      """,
      params: [
        allowed_tags:
          "Override the allowed tag list. Defaults to Tymeslot.Test.TagTaxonomy.all()."
      ]
    ]

  alias Credo.Code
  alias Credo.IssueMeta
  alias Tymeslot.Test.TagTaxonomy

  @doc false
  @impl Credo.Check
  @spec run(Credo.SourceFile.t(), keyword()) :: list()
  def run(%Credo.SourceFile{} = source_file, params) do
    if test_file?(source_file.filename) do
      issue_meta = IssueMeta.for(source_file, params)
      allowed_tags = Keyword.get(params, :allowed_tags, TagTaxonomy.all())
      Code.prewalk(source_file, &traverse(&1, &2, issue_meta, allowed_tags))
    else
      []
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp test_file?(filename) do
    String.ends_with?(filename, "_test.exs") and
      String.contains?(filename, "/test/") and
      not String.contains?(filename, "/test/support/")
  end

  # Returns true only for modules whose last name segment ends with "Test",
  # e.g. Tymeslot.Auth.AuthTest — skips inline helper/mock modules.
  defp test_module?({:__aliases__, _, segments}) when is_list(segments) do
    case List.last(segments) do
      name when is_atom(name) -> name |> to_string() |> String.ends_with?("Test")
      _ -> false
    end
  end

  defp test_module?(_), do: false

  # Multi-expression module body — only check modules whose name ends in "Test"
  defp traverse(
         {:defmodule, meta, [name, [do: {:__block__, _meta, body}]]} = ast,
         issues,
         issue_meta,
         allowed_tags
       ) do
    if test_module?(name) do
      check_body(ast, meta[:line], body, issues, issue_meta, allowed_tags)
    else
      {ast, issues}
    end
  end

  # Single-expression module body (no __block__ wrapper)
  defp traverse(
         {:defmodule, meta, [name, [do: single_expr]]} = ast,
         issues,
         issue_meta,
         allowed_tags
       )
       when not is_list(single_expr) do
    if test_module?(name) do
      check_body(ast, meta[:line], [single_expr], issues, issue_meta, allowed_tags)
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta, _allowed_tags), do: {ast, issues}

  defp check_body(ast, line_no, body, issues, issue_meta, allowed_tags) do
    tags = collect_moduletags(body)

    if has_valid_tag?(tags, allowed_tags) do
      {ast, issues}
    else
      {ast, [build_issue(issue_meta, line_no, tags, allowed_tags) | issues]}
    end
  end

  # Collect tag identifiers from the direct body of a module (non-recursive).
  # Handles:
  #   @moduletag :some_atom          → [:some_atom]
  #   @moduletag key: val            → [:key]
  #   @moduletag key1: v, key2: v    → [:key1, :key2]
  defp collect_moduletags(body) when is_list(body) do
    Enum.flat_map(body, fn
      {:@, _, [{:moduletag, _, [tag]}]} when is_atom(tag) ->
        [tag]

      {:@, _, [{:moduletag, _, [keyword_list]}]} when is_list(keyword_list) ->
        Keyword.keys(keyword_list)

      _ ->
        []
    end)
  end

  defp has_valid_tag?(tags, allowed_tags), do: Enum.any?(tags, &(&1 in allowed_tags))

  defp build_issue(issue_meta, line_no, [], _allowed_tags) do
    format_issue(issue_meta,
      message:
        "Test module is missing a @moduletag from the approved taxonomy. " <>
          "See Tymeslot.Test.TagTaxonomy for the list of allowed tags.",
      line_no: line_no,
      trigger: "defmodule"
    )
  end

  defp build_issue(issue_meta, line_no, tags, allowed_tags) do
    invalid = tags -- allowed_tags

    format_issue(issue_meta,
      message:
        "Test module uses unrecognised @moduletag(s): #{inspect(invalid)}. " <>
          "Replace with an approved tag from Tymeslot.Test.TagTaxonomy.",
      line_no: line_no,
      trigger: "@moduletag"
    )
  end
end
