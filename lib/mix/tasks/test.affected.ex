defmodule Mix.Tasks.Test.Affected do
  @shortdoc "Runs the tests your changes affect, selected by mirror path and domain tag"

  @moduledoc """
  Runs the affected slice of the suite instead of all of it.

      $ mix test.affected                    # uncommitted work, staged and not
      $ mix test.affected --base main        # everything on this branch
      $ mix test.affected --explain          # print the plan, run nothing
      $ mix test.affected -- --max-failures 1

  Anything after `--` is passed to `mix test` untouched.

  ## What it selects

  Changed test files run directly. Changed lib files resolve to their mirror
  test directory, and then widen to every test file carrying a domain tag that
  directory declares, which is what pulls in the worker, email and LiveView
  tests for the domain you touched. `Tymeslot.TestAffected.Selection` documents
  why the selection is drawn from tags rather than from the dependency graph,
  and what that costs.

  ## What it will not do

  It never narrows silently. A path it does not recognise, a lib file with no
  mirror directory, a change to `config/`, `test/support/`, `mix.exs` or a
  migration, or a selection large enough that targeting stops paying, all
  resolve to the full suite and say so.

  It is the pre-commit check, not the gate. It selects the tests a careful
  developer would select, which is not the same as every test a change can
  break: cross-domain coupling is exactly what a tag cannot express. Run
  `./mix.sh precommit` before pushing.
  """

  use Mix.Task

  alias Tymeslot.TestAffected.Selection
  alias Tymeslot.TestAffected.Workspace

  @switches [base: :string, explain: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, passthrough} = OptionParser.parse!(argv, strict: @switches)

    changed = Workspace.changed_files(opts[:base])
    index = Workspace.index()
    plan = Selection.plan(changed, index)

    report(changed, plan, index)

    if opts[:explain], do: :ok, else: execute(plan, passthrough)
  end

  ## Reporting

  defp report(changed, plan, index) do
    Mix.shell().info("#{length(changed)} changed #{pluralise(length(changed), "file")}")
    Enum.each(plan.reasons, &Mix.shell().info("  #{&1}"))

    case plan.scope do
      :nothing ->
        Mix.shell().info("\nnothing to run: no change reaches the Elixir suite")

      :full_suite ->
        Mix.shell().info("\nrunning the full suite#{migration_note(plan)}")

      :selection ->
        share = Selection.percent(length(plan.files), MapSet.size(index.test_files))

        Mix.shell().info(
          "\nrunning #{length(plan.files)} test #{pluralise(length(plan.files), "file")} (#{share} of the suite)"
        )
    end
  end

  defp migration_note(%{include_migrations?: true}), do: ", including the migrations tag"
  defp migration_note(_plan), do: ""

  defp pluralise(1, word), do: word
  defp pluralise(_count, word), do: word <> "s"

  ## Running

  defp execute(%{scope: :nothing}, _passthrough), do: :ok

  defp execute(%{scope: :full_suite} = plan, passthrough) do
    Mix.Task.run("test", migration_args(plan) ++ passthrough)
  end

  defp execute(%{scope: :selection} = plan, passthrough) do
    # Every path came from the on-disk index, so none can be silently dropped:
    # `mix test` discards paths that match nothing and still exits 0 when at
    # least one other path matched.
    Mix.Task.run("test", plan.files ++ passthrough)
  end

  defp migration_args(%{include_migrations?: true}), do: ["--include", "migrations"]
  defp migration_args(_plan), do: []
end
