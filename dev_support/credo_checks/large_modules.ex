defmodule CredoChecks.LargeModules do
  @moduledoc """
  Detects modules that are longer than the soft or the hard line limit.

  Large modules can be difficult to understand, maintain, and test. They often
  indicate that a module has too many responsibilities and should be broken down
  into smaller, more focused modules.

  The check has two bands, so a module that has just crossed the line can be
  split in a later change rather than blocking the one that grew it:

    * **Over `max_lines` (650):** a warning. The issue is reported with exit
      status 0, so `mix credo --strict` and the precommit gate still pass, and
      the gate repeats the warning in its summary.
    * **Over `hard_max_lines` (750):** an error that fails the run, as any other
      design issue does.

  Credo ORs the exit status of every issue it reports, which is what lets one
  check produce both a warning and an error.

  ## Configuration

      {CredoChecks.LargeModules, max_lines: 650, hard_max_lines: 750}
  """

  use Credo.Check,
    base_priority: :low,
    category: :design,
    # Non-zero so the hard cap is actually enforced: a module over
    # `hard_max_lines` fails `mix credo --strict`. `2` matches the `:design`
    # category default that the other enforced custom checks rely on. Issues in
    # the warning band override it with 0 (see `exit_status/1`).
    exit_status: 2,
    param_defaults: [max_lines: 650, hard_max_lines: 750],
    explanations: [
      check: """
      Detects modules that are longer than the configured line limits.

      Over the soft limit (`max_lines`) the module is reported as a warning that
      does not fail the run; over the hard limit (`hard_max_lines`) it is an
      error. Split a module in the warning band into smaller, more focused
      modules before it reaches the hard limit.
      """,
      params: [
        max_lines: "The soft limit: over it, a warning that does not fail the run (default: 650)",
        hard_max_lines: "The hard limit: over it, an error that fails the run (default: 750)"
      ]
    ]

  alias Credo.Check.Params
  alias Credo.IssueMeta
  alias Credo.SourceFile

  # The precommit runner counts issues in the warning band by this prefix
  # (`Tymeslot.Precommit.Runner`), so keep it at the very start of the message,
  # where Credo's line wrapping cannot split it.
  @warning_prefix "Soft limit:"

  @doc false
  @spec warning_prefix() :: String.t()
  def warning_prefix, do: @warning_prefix

  @doc false
  @impl Credo.Check
  @spec run(SourceFile.t(), any) :: list()
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    limits = %{
      soft: Params.get(params, :max_lines, __MODULE__),
      hard: Params.get(params, :hard_max_lines, __MODULE__)
    }

    line_count = source_file |> SourceFile.lines() |> length()

    case band(line_count, limits) do
      nil -> []
      band -> [issue_for(issue_meta, band, line_count, extract_module_name(source_file), limits)]
    end
  end

  defp band(line_count, %{hard: hard}) when line_count > hard, do: :error
  defp band(line_count, %{soft: soft}) when line_count > soft, do: :warning
  defp band(_line_count, _limits), do: nil

  defp extract_module_name(%SourceFile{} = source_file) do
    # `SourceFile.ast/1` returns the AST itself and raises when it is missing.
    case SourceFile.ast(source_file) do
      {:defmodule, _, [{:__aliases__, _, module_parts}, _]} ->
        Enum.map_join(module_parts, ".", &to_string/1)

      _other ->
        module_name_from_filename(source_file)
    end
  rescue
    _other -> module_name_from_filename(source_file)
  end

  defp module_name_from_filename(%SourceFile{filename: filename}) do
    filename |> Path.basename() |> Path.rootname() |> Macro.camelize()
  end

  defp issue_for(issue_meta, band, line_count, module_name, limits) do
    format_issue(issue_meta,
      message: message(band, line_count, module_name, limits),
      line_no: 1,
      trigger: "defmodule",
      exit_status: exit_status(band)
    )
  end

  defp message(:warning, line_count, module_name, %{soft: soft, hard: hard}) do
    "#{@warning_prefix} `#{module_name}` has #{line_count} lines (warns over #{soft}, fails " <>
      "over #{hard}). Split it into smaller, more focused modules, or file a deferred/ " <>
      "ticket to do so."
  end

  defp message(:error, line_count, module_name, %{hard: hard}) do
    "Module `#{module_name}` has #{line_count} lines, which exceeds the hard limit of " <>
      "#{hard} lines. Break this module into smaller, more focused modules."
  end

  defp exit_status(:warning), do: 0
  # nil falls through to the check's own exit status, so a configured override
  # in .credo.exs still applies to the hard limit.
  defp exit_status(:error), do: nil
end
