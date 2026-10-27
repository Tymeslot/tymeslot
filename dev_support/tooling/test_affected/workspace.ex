defmodule Tymeslot.TestAffected.Workspace do
  @moduledoc """
  The disk and git access behind `mix test.affected` and `mix precommit --affected`.

  `Tymeslot.TestAffected.Selection` is pure and takes what this module reads:
  the changed paths, and an index of the suite as it exists on disk.
  """

  alias Tymeslot.Test.TagTaxonomy
  alias Tymeslot.TestAffected.Selection

  @compile {:no_warn_undefined, TagTaxonomy}

  @taxonomy_paths ["test/support/tag_taxonomy.ex", "../tymeslot/test/support/tag_taxonomy.ex"]

  @doc """
  Lists the paths changed in the repository at `dir`, relative to its root.

  With no `base`, that is the working tree: staged, unstaged and untracked.
  With one, it is also every commit since the branch left `base`.
  """
  @spec changed_files(String.t() | nil, Path.t()) :: [String.t()]
  def changed_files(base, dir \\ ".")

  def changed_files(nil, dir), do: working_tree_changes(dir)

  def changed_files(base, dir) do
    {out, 0} = System.cmd("git", ["diff", "--name-only", "#{base}...HEAD"], cd: dir, env: [])
    Enum.uniq(String.split(out, "\n", trim: true) ++ working_tree_changes(dir))
  end

  # `--porcelain` rather than `diff`, so staged, unstaged and untracked changes
  # are all seen. An unstaged new test file is exactly the thing you want run.
  defp working_tree_changes(dir) do
    {out, 0} =
      System.cmd("git", ["status", "--porcelain", "--untracked-files=all"], cd: dir, env: [])

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

  @doc "Indexes the current repository's suite: its test files and their domain tags."
  @spec index() :: Selection.index()
  def index do
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

  # Core compiles the taxonomy into `:test` only, and the SaaS build never does,
  # because a path dependency is compiled without its owner's test paths. Load
  # it from source otherwise, the same file Credo is pointed at. That covers
  # `mix precommit --affected` too, which runs under `:dev` in both repos.
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
end
