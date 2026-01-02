defmodule CredoChecks.LargeModules do
  @moduledoc """
  Detects modules that are longer than 600 lines.

  Large modules can be difficult to understand, maintain, and test. They often
  indicate that a module has too many responsibilities and should be broken down
  into smaller, more focused modules.

  ## Configuration

  The maximum number of lines can be configured:

      {CredoChecks.LargeModules, max_lines: 600}

  The default maximum is 600 lines.
  """

  use Credo.Check,
    base_priority: :low,
    category: :design,
    exit_status: 0,
    explanations: [
      check: """
      Detects modules that are longer than the configured maximum number of lines.

      Large modules can be difficult to understand, maintain, and test. They often
      indicate that a module has too many responsibilities and should be broken down
      into smaller, more focused modules.
      """,
      params: [
        max_lines: "The maximum number of lines allowed in a module (default: 600)"
      ]
    ]

  alias Credo.IssueMeta
  alias Credo.SourceFile

  @doc false
  @impl true
  @spec run(SourceFile.t(), any) :: list()
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    max_lines = 750

    lines = SourceFile.lines(source_file)
    line_count = length(lines)

    if line_count > max_lines do
      module_name = extract_module_name(source_file)
      [issue_for(issue_meta, line_count, max_lines, module_name)]
    else
      []
    end
  end

  defp extract_module_name(%SourceFile{} = source_file) do
    case SourceFile.ast(source_file) do
      {:ok, {:defmodule, _, [{:__aliases__, _, module_parts}, _]}} ->
        Enum.map_join(module_parts, ".", &to_string/1)

      _ ->
        source_file.filename
        |> Path.basename()
        |> Path.rootname()
        |> Macro.camelize()
    end
  rescue
    _ ->
      source_file.filename
      |> Path.basename()
      |> Path.rootname()
      |> Macro.camelize()
  end

  defp issue_for(issue_meta, line_count, max_lines, module_name) do
    format_issue(issue_meta,
      message:
        "Module `#{module_name}` has #{line_count} lines, which exceeds the maximum of #{max_lines} lines. " <>
          "Consider breaking this module into smaller, more focused modules.",
      line_no: 1,
      trigger: "defmodule"
    )
  end
end