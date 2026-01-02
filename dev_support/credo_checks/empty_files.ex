defmodule CredoChecks.EmptyFiles do
  @moduledoc """
  Detects empty files in the codebase.

  Empty files can indicate:
  - Forgotten file content
  - Unfinished implementation
  - Files that should be removed
  - Placeholder files left behind

  This check helps maintain code cleanliness by identifying files that contain
  no meaningful content (only whitespace, comments, or nothing at all).
  """

  use Credo.Check,
    base_priority: :low,
    category: :design,
    exit_status: 0,
    explanations: [
      check: """
      Detects empty files in the codebase.

      Empty files can indicate forgotten file content, unfinished implementation,
      files that should be removed, or placeholder files left behind.
      """,
      params: []
    ]

  alias Credo.IssueMeta
  alias Credo.SourceFile

  @doc "Internal callback for Credo.Check"
  @spec run(SourceFile.t(), keyword()) :: list()
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    # Allow configuration via params to avoid hard-coded branches Dialyzer flags as unreachable
    ignore_test_files = Keyword.get(params, :ignore_test_files, true)
    minimum_lines = Keyword.get(params, :minimum_lines, 1)

    if should_check_file?(source_file, ignore_test_files) do
      check_file_content(source_file, issue_meta, minimum_lines)
    else
      []
    end
  end

  defp should_check_file?(%SourceFile{filename: filename}, ignore_test_files) do
    not (ignore_test_files and test_file?(filename))
  end

  defp test_file?(filename) do
    String.contains?(filename, "/test/") or String.ends_with?(filename, "_test.exs")
  end

  defp check_file_content(%SourceFile{} = source_file, issue_meta, minimum_lines) do
    content_lines = get_meaningful_lines(source_file)

    if length(content_lines) < minimum_lines do
      [issue_for(issue_meta, source_file, length(content_lines))]
    else
      []
    end
  end

  defp get_meaningful_lines(%SourceFile{} = source_file) do
    source_file
    |> SourceFile.lines()
    |> Enum.map(fn
      {_, line} -> line
      line when is_binary(line) -> line
    end)
    |> Enum.filter(&meaningful_line?/1)
  end

  defp meaningful_line?(line) do
    trimmed = String.trim(line)

    # A line is meaningful if it's not empty and not just a comment
    trimmed != "" and not comment_only_line?(trimmed)
  end

  defp comment_only_line?(line) do
    String.starts_with?(line, "#")
  end

  defp issue_for(issue_meta, %SourceFile{filename: filename}, line_count) do
    message =
      case line_count do
        0 -> "File `#{Path.basename(filename)}` is completely empty."
        count -> "File `#{Path.basename(filename)}` contains only #{count} meaningful line(s)."
      end

    format_issue(issue_meta,
      message: message,
      line_no: 1,
      trigger: Path.basename(filename)
    )
  end
end