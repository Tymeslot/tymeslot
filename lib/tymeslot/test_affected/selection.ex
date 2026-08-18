defmodule Tymeslot.TestAffected.Selection do
  @moduledoc """
  Works out which test files a set of changed files affects.

  The engine behind `mix test.affected`. Pure: it takes the changed paths and
  an index of the suite, and returns a plan. All disk and git access lives in
  the task.

  ## Why paths and tags, and not the dependency graph

  The obvious approach is to ask the compiler which tests depend on the changed
  modules. It does not work here. Test files are never in the Elixir compiler
  manifest (`elixirc_paths(:test)` is `["lib", "test/support"]`, and `.exs`
  files are loaded by ExUnit at runtime), so `mix xref` has no test-to-lib
  edges at all. The one structure that does record them is ExUnit's
  `compile.test_stale` manifest, and its transitive walk saturates: measured on
  this suite, a one-line change selects the same 9,569 of 12,161 tests whether
  it lands in `Tymeslot.Auth.Authentication` or in a leaf Oban worker, because
  the module graph is cyclic and dense. It costs 88% of a full run to learn
  nothing.

  So affectedness is taken from declared intent instead: the `@moduletag`
  domain tag is a human asserting what a test is about, which is a claim the
  graph cannot make. Measured against 156 real commits, selecting the mirror
  directory plus every domain tag it declares covers the tests the author
  edited in 94% of them, at a median of 26% of the suite.

  ## Widen, never narrow

  Every rule here fails towards running more. An unrecognised path, a lib file
  with no mirror directory, or a selection large enough that targeting is
  pointless all resolve to the full suite. A selection that is quietly too
  small is the one failure this tool must not have, because it reports success.
  """

  @typedoc "Index of the suite as it exists on disk."
  @type index :: %{
          test_files: MapSet.t(String.t()),
          tags: %{String.t() => MapSet.t(atom())},
          domain_tags: MapSet.t(atom())
        }

  @typedoc "What to run, and why."
  @type plan :: %{
          scope: :selection | :full_suite | :nothing,
          files: [String.t()],
          tags: [atom()],
          include_migrations?: boolean(),
          reasons: [String.t()]
        }

  # A selection this large is not worth targeting: it costs most of a full run
  # without its confidence. Measured p90 for a focused commit is 85%, so this
  # fires on the tail where the tag sweep degenerates, not on the common case.
  @full_suite_threshold 0.5

  @source_extensions [".html.heex", ".heex", ".ex"]

  @ignored_prefixes ~w[assets/ priv/static/ priv/cert/ .github/ .gitea/ doc/ dev/]
  @ignored_extensions ~w[.md .txt .json .yml .yaml .css .js .png .svg .ico]

  @widening_files ~w[mix.exs mix.lock .formatter.exs]
  @widening_prefixes ~w[config/ test/support/ test/test_helper.exs]
  @migration_prefixes ~w[priv/repo/migrations/ priv/saas_repo/migrations/]

  @doc """
  Builds the plan for `changed` against `index`.

  `changed` are repo-relative paths as git reports them, including deletions;
  paths that no longer exist are dropped by intersecting with the index, so the
  plan can never name a file `mix test` would silently skip.
  """
  @spec plan([String.t()], index()) :: plan()
  def plan(changed, index) do
    changed
    |> Enum.map(&classify/1)
    |> Enum.reduce(empty_plan(), &apply_classification(&1, &2, index))
    |> finalise(index)
  end

  @doc """
  Classifies one changed path.

  `:ignore` cannot affect the Elixir suite. `:widen` is compiled into, or read
  by, every test. `:migrations` changes the database shape underneath all of
  them. `{:test, path}` is a test file in its own right, and `{:lib, path}` is
  application code to resolve through its mirror directory.
  """
  @spec classify(String.t()) ::
          :ignore
          | {:widen, String.t()}
          | {:migrations, String.t()}
          | {:test, String.t()}
          | {:lib, String.t()}
  def classify(path) do
    cond do
      path in @widening_files -> {:widen, path}
      starts_with_any?(path, @migration_prefixes) -> {:migrations, path}
      starts_with_any?(path, @widening_prefixes) -> {:widen, path}
      String.ends_with?(path, "_test.exs") -> {:test, path}
      starts_with_any?(path, @ignored_prefixes) -> :ignore
      Path.extname(path) in @ignored_extensions -> :ignore
      String.starts_with?(path, "lib/") -> {:lib, path}
      true -> {:widen, path}
    end
  end

  @doc """
  Maps a lib path to the deepest existing mirror test directory.

  `lib/tymeslot/auth/oauth/google.ex` mirrors to `test/tymeslot/auth/oauth`,
  walking up a segment at a time when a directory has no counterpart. Around a
  third of lib directories do not mirror exactly, so the walk matters; it stops
  at `test/` rather than selecting the whole suite by accident.
  """
  @spec mirror_dir(String.t(), index()) :: String.t() | nil
  def mirror_dir(path, index) do
    path
    |> Path.dirname()
    |> String.replace_prefix("lib/", "test/")
    |> walk_up(index)
  end

  defp walk_up("test", _index), do: nil
  defp walk_up(".", _index), do: nil

  defp walk_up(dir, index) do
    cond do
      # `test/tymeslot` or `test/tymeslot_web` is not a mirror of anything, it
      # is most of the suite. Widening honestly beats a selection that only
      # looks targeted.
      root?(dir) -> nil
      dir_populated?(dir, index) -> dir
      true -> dir |> Path.dirname() |> walk_up(index)
    end
  end

  defp root?(dir), do: dir |> Path.split() |> length() <= 2

  defp dir_populated?(dir, index), do: Enum.any?(index.test_files, &in_dir?(&1, dir))

  defp in_dir?(file, dir), do: String.starts_with?(file, dir <> "/")

  defp empty_plan do
    %{
      scope: :selection,
      files: MapSet.new(),
      tags: MapSet.new(),
      include_migrations?: false,
      reasons: []
    }
  end

  defp apply_classification(:ignore, plan, _index), do: plan

  defp apply_classification({:widen, path}, plan, _index) do
    %{plan | scope: :full_suite, reasons: ["#{path}: affects the whole suite" | plan.reasons]}
  end

  defp apply_classification({:migrations, path}, plan, _index) do
    %{
      plan
      | scope: :full_suite,
        include_migrations?: true,
        reasons: ["#{path}: changes the database shape" | plan.reasons]
    }
  end

  defp apply_classification({:test, path}, plan, index) do
    if MapSet.member?(index.test_files, path) do
      %{
        plan
        | files: MapSet.put(plan.files, path),
          reasons: ["#{path}: changed test file" | plan.reasons]
      }
    else
      plan
    end
  end

  defp apply_classification({:lib, path}, plan, index) do
    case mirror(path, index) do
      nil ->
        %{
          plan
          | scope: :full_suite,
            reasons: ["#{path}: no mirror test file or directory" | plan.reasons]
        }

      {seed, label} ->
        tags = domain_tags_of(seed, index)
        tagged = Enum.filter(index.test_files, &tagged_with_any?(&1, tags, index))

        %{
          plan
          | files: plan.files |> union(seed) |> union(tagged),
            tags: MapSet.union(plan.tags, tags),
            reasons: ["#{path}: #{label} + #{describe_tags(tags)}" | plan.reasons]
        }
    end
  end

  @doc """
  Resolves a lib path to the test files the selection is seeded from.

  The mirror *file* is preferred over the mirror directory. It carries the same
  domain tags, so the tag sweep that does the real work is unchanged, while the
  seed stops dragging in every sibling: measured over 156 commits that is 15%
  of the suite rather than 26%, for six tenths of a point of recall. The
  directory only stands in when no mirror file exists, which is also what stops
  a top-level context module seeding itself with the whole of `test/tymeslot`.
  """
  @spec mirror(String.t(), index()) :: {[String.t()], String.t()} | nil
  def mirror(path, index) do
    case mirror_file(path, index) do
      nil -> mirror_from_dir(path, index)
      file -> {[file], file}
    end
  end

  defp mirror_from_dir(path, index) do
    case mirror_dir(path, index) do
      nil -> nil
      dir -> {Enum.filter(index.test_files, &in_dir?(&1, dir)), dir <> "/"}
    end
  end

  @doc """
  Maps a lib path to its mirror test file, when one exists.

  `lib/tymeslot/auth/oauth/google.ex` mirrors to
  `test/tymeslot/auth/oauth/google_test.exs`.
  """
  @spec mirror_file(String.t(), index()) :: String.t() | nil
  def mirror_file(path, index) do
    candidate =
      path
      |> String.replace_prefix("lib/", "test/")
      |> strip_source_extension()
      |> Kernel.<>("_test.exs")

    if MapSet.member?(index.test_files, candidate), do: candidate
  end

  # `.html.heex` first: a colocated template belongs to its LiveView, so
  # `foo_live.html.heex` should find `foo_live_test.exs` rather than look for a
  # test named after the template.
  defp strip_source_extension(path) do
    Enum.find_value(@source_extensions, path, fn ext ->
      if String.ends_with?(path, ext), do: String.replace_suffix(path, ext, "")
    end)
  end

  defp domain_tags_of(files, index) do
    files
    |> Enum.flat_map(&(index.tags |> Map.get(&1, MapSet.new()) |> MapSet.to_list()))
    |> Enum.filter(&MapSet.member?(index.domain_tags, &1))
    |> MapSet.new()
  end

  defp tagged_with_any?(file, tags, index) do
    index.tags |> Map.get(file, MapSet.new()) |> MapSet.disjoint?(tags) |> Kernel.not()
  end

  defp union(set, files), do: Enum.into(files, set)

  @tags_shown 6

  defp describe_tags(tags) do
    case tags |> MapSet.to_list() |> Enum.sort() do
      [] ->
        "no domain tag declared there"

      list when length(list) <= @tags_shown ->
        Enum.map_join(list, ", ", &"--only #{&1}")

      list ->
        "#{Enum.map_join(Enum.take(list, @tags_shown), ", ", &"--only #{&1}")} and #{length(list) - @tags_shown} more"
    end
  end

  defp finalise(%{scope: :full_suite} = plan, _index) do
    %{plan | files: [], tags: [], reasons: Enum.reverse(plan.reasons)}
  end

  defp finalise(plan, index) do
    files = plan.files |> MapSet.to_list() |> Enum.sort()
    total = MapSet.size(index.test_files)

    cond do
      files == [] ->
        %{plan | scope: :nothing, files: [], tags: [], reasons: Enum.reverse(plan.reasons)}

      total > 0 and length(files) / total >= @full_suite_threshold ->
        note =
          "selection is #{percent(length(files), total)} of the suite; the full run is barely dearer"

        %{
          plan
          | scope: :full_suite,
            files: [],
            tags: [],
            reasons: Enum.reverse([note | plan.reasons])
        }

      true ->
        %{
          plan
          | files: files,
            tags: plan.tags |> MapSet.to_list() |> Enum.sort(),
            reasons: Enum.reverse(plan.reasons)
        }
    end
  end

  @doc "Formats a count as a percentage of the suite, for reporting."
  @spec percent(non_neg_integer(), pos_integer()) :: String.t()
  def percent(count, total), do: "#{round(count / total * 100)}%"

  defp starts_with_any?(path, prefixes), do: Enum.any?(prefixes, &String.starts_with?(path, &1))
end
