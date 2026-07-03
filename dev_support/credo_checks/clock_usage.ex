defmodule CredoChecks.ClockUsage do
  @moduledoc """
  Flags direct wall-clock reads (`DateTime.utc_now/0,1`, `NaiveDateTime.utc_now/0,1`,
  `Date.utc_today/0`, `Time.utc_now/0,1`) inside namespaces that have been made
  "clock-managed" — i.e. that read the current time through `Tymeslot.Clock` so
  their time-dependent behaviour can be frozen and tested deterministically.

  Adoption is incremental: as each namespace is migrated to `Tymeslot.Clock`, add
  its path to the `:paths` param so this check keeps it from regressing. It is
  deliberately NOT a codebase-wide ban — un-migrated code still reads the system
  clock directly, and timestamp-only writes elsewhere are fine.

  ## Params

  - `:paths` — list of path substrings the check applies to
    (default: `["/tymeslot/bookings/"]`).

  ## Examples

      # Bad — direct wall-clock read in a clock-managed module
      def past?(m), do: DateTime.compare(m.end_time, DateTime.utc_now()) == :lt

      # Good — read through the injectable clock
      def past?(m), do: DateTime.compare(m.end_time, Clock.utc_now()) == :lt
  """

  use Credo.Check,
    base_priority: :normal,
    category: :warning,
    param_defaults: [paths: ["/tymeslot/bookings/"]],
    explanations: [
      check: """
      Modules in a clock-managed namespace must read the current time through
      `Tymeslot.Clock` (`Clock.utc_now/0`, `Clock.utc_today/0`) rather than
      calling `DateTime.utc_now/0` and friends directly. This keeps their
      time-dependent behaviour testable with a frozen clock.
      """,
      params: [paths: "List of path substrings this check applies to."]
    ]

  alias Credo.Check.Params
  alias Credo.IssueMeta
  alias Credo.SourceFile

  # {module_last_segment, function} pairs that read the wall clock.
  @flagged [
    {:DateTime, :utc_now},
    {:NaiveDateTime, :utc_now},
    {:Date, :utc_today},
    {:Time, :utc_now}
  ]

  @doc false
  @impl Credo.Check
  @spec run(SourceFile.t(), keyword()) :: list()
  def run(%SourceFile{} = source_file, params) do
    filename = source_file.filename
    paths = Params.get(params, :paths, __MODULE__)

    if managed?(filename, paths) and not excluded?(filename) do
      issue_meta = IssueMeta.for(source_file, params)
      Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
    else
      []
    end
  end

  defp managed?(filename, paths), do: Enum.any?(paths, &String.contains?(filename, &1))

  defp excluded?(filename) do
    String.contains?(filename, "/test/") or
      String.starts_with?(filename, "test/") or
      String.contains?(filename, "/deps/") or
      Path.basename(filename) == "clock.ex"
  end

  defp traverse(
         {{:., _dot_meta, [{:__aliases__, _alias_meta, [module]}, func]}, meta, _args} = ast,
         issues,
         issue_meta
       ) do
    if {module, func} in @flagged do
      trigger = "#{module}.#{func}"

      issue =
        format_issue(issue_meta,
          message:
            "`#{trigger}` reads the wall clock directly in a clock-managed " <>
              "module — use `Tymeslot.Clock` so time can be frozen in tests.",
          line_no: meta[:line],
          trigger: trigger
        )

      {ast, [issue | issues]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}
end
