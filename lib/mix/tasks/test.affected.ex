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

  alias Tymeslot.Test.TagTaxonomy
  alias Tymeslot.TestAffected.Selection

  @compile {:no_warn_undefined, TagTaxonomy}

  @taxonomy_paths ["test/support/tag_taxonomy.ex", "../tymeslot/test/support/tag_taxonomy.ex"]
  @switches [base: :string, explain: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, passthrough} = OptionParser.parse!(argv, strict: @switches)

    changed = changed_files(opts[:base])
    index = build_index()
    plan = Selection.plan(changed, index)

    report(changed, plan, index)

    if opts[:explain], do: :ok, else: execute(plan, passthrough)
  end

  ## Changes

  defp changed_files(nil), do: working_tree_changes()

  defp changed_files(base) do
    {out, 0} = System.cmd("git", ["diff", "--name-only", "#{base}...HEAD"], env: [])
    Enum.uniq(String.split(out, "\n", trim: true) ++ working_tree_changes())
  end

  # `--porcelain` rather than `diff`, so staged, unstaged and untracked changes
  # are all seen. An unstaged new test file is exactly the thing you want run.
  defp working_tree_changes do
    {out, 0} = System.cmd("git", ["status", "--porcelain", "--untracked-files=all"], env: [])

    out
    |> String.split("\n", trim: true)
    |> Enum.map(&entry_path/1)
    |> Enum.reject(&is_nil/1)
  end

  defp entry_path(line) do
    case line |> String.slice(3..-1//1) |> String.split(" -> ") do
      [_old, new] -> unquote_path(new)
      [path] -> unquote_path(path)
    end
  end

  defp unquote_path(path), do: path |> String.trim() |> String.trim(~s("))

  ## Index

  defp build_index do
    # The taxonomy is resolved first because `tags_in/2` filters what it finds
    # against it, rather than the other way round.
    domain_tags = domain_tags()
    test_files = "test" |> Path.join("**/*_test.exs") |> Path.wildcard() |> MapSet.new()

    %{
      test_files: test_files,
      tags: Map.new(test_files, &{&1, tags_in(&1, domain_tags)}),
      domain_tags: domain_tags
    }
  end

  defp tags_in(file, domain_tags),
    do: Selection.tags_in_source(File.read!(file), domain_tags)

  # Core compiles the taxonomy into `:test`; the SaaS build does not, because a
  # path dependency is compiled without its owner's test paths. Load it from
  # the sibling checkout there, the same file Credo is pointed at.
  defp domain_tags do
    unless Code.ensure_loaded?(TagTaxonomy) do
      case Enum.find(@taxonomy_paths, &File.exists?/1) do
        nil ->
          Mix.raise(
            "cannot find tag_taxonomy.ex; expected one of: #{Enum.join(@taxonomy_paths, ", ")}"
          )

        path ->
          Code.require_file(path)
      end
    end

    TagTaxonomy.by_category() |> Map.fetch!(:domain) |> MapSet.new()
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
