defmodule Tymeslot.TestAffected.Selection do
  @moduledoc """
  Works out which test files a set of changed files affects.

  The engine behind `mix test.affected`. Pure: it takes the changed paths and
  an index of the suite, and returns a plan. All disk and git access lives in
  `Tymeslot.TestAffected.Workspace`.

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

  ## Files that are not code

  A path that is neither code nor a test reaches the suite only through
  whatever reads it, so it is resolved through whoever *names* it: the test
  files whose source contains the path (or one of its parent directories, down
  to two segments), plus the selection of every source module that does. Three
  kinds differ only in what happens when nothing names them:

    * **tooling** (`.credo.exs`, `.formatter.exs`, Dockerfiles, git hooks,
      `scripts/`, uncompiled files under `dev_support/`) is read by the gate's
      tools and by developers, not by the application, so unnamed it selects
      nothing.
    * **translations** (`priv/gettext/`) are compiled into the Gettext backend,
      but the English catalogues carry no `msgstr`, so a change shows only in
      another locale: they select the `:i18n` domain, plus whoever names them.
      An English `msgstr` override would reach English assertions the
      selection does not cover; the push-time gate is the backstop.
    * **data** (anything else, such as `priv/tz/` or `priv/professions/`) may
      be read through a path built at runtime, so unnamed it widens.

  ## Changes upstream

  A repository consuming another as a path dependency builds against that
  dependency's working tree, which its own diff cannot show. `plan/3` takes
  those changes as `:upstream` and resolves them against the dependency's own
  index, then carries over what the two suites share: the domain tags. Tests
  in a domain no upstream test carries (the consumer's own features, which
  wrap upstream code but which no upstream tag can name) are selected whole by
  any upstream change that reaches code, since the tag sweep cannot reach
  them. A widening upstream change widens here too; an upstream test file
  changes nothing here. The consumer can also name a directory of its own
  tests that exist to check the two repositories against each other
  (`:upstream_tests`); any upstream change that reaches the build selects all
  of them.

  ## Widen, never narrow

  Every rule here fails towards running more. An unrecognised path, a lib file
  with no mirror directory, a data file nothing names, or a selection large
  enough that targeting is pointless all resolve to the full suite. A selection
  that is quietly too small is the one failure this tool must not have, because
  it reports success.
  """

  @typedoc "Index of the suite as it exists on disk."
  @type index :: %{
          test_files: MapSet.t(String.t()),
          tags: %{String.t() => MapSet.t(atom())},
          domain_tags: MapSet.t(atom()),
          sources: %{String.t() => String.t()}
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

  # Anchored to the start of a line, so a `@moduletag` inside a one-line string
  # (a test of this very reader, say) is not read as the module's own.
  @moduletag_re ~r/^\s*@moduletag\s+:?([a-z_0-9]+)/m
  # Heredoc bodies are string data, often the source of a module under test.
  @heredoc_re ~r/("""|''')[\s\S]*?\1/
  @defmodule_re ~r/defmodule\s+([A-Z][\w.]*)/

  @ignored_prefixes ~w[assets/ priv/static/ priv/cert/ .github/ .gitea/ doc/ dev/]
  @ignored_extensions ~w[.md .txt .json .yml .yaml .css .js .mjs .cjs .png .svg .ico]

  @widening_files ~w[mix.exs mix.lock]
  @widening_prefixes ~w[config/ test/support/ test/test_helper.exs]
  @migration_prefixes ~w[priv/repo/migrations/ priv/saas_repo/migrations/]

  # Code resolved through a mirror directory: `lib/x` to `test/x`, and the
  # dev tooling and Credo checks in `dev_support/x` to `test/dev_support/x`.
  @source_prefixes ~w[lib/ dev_support/]

  @translation_prefix "priv/gettext/"
  @translation_tag :i18n

  # Read by the gate's tools, the build image or a developer, never by the
  # application: matched by basename, so a nested `.formatter.exs` counts too.
  @tooling_files ~w[.formatter.exs .credo.exs .dialyzer_ignore.exs .sobelow-conf .sobelow-skips .env.example]
  @tooling_names ~r/^(Dockerfile|LICENSE)|\.dockerignore$/
  @tooling_prefixes ~w[.githooks/ scripts/ dev_support/]

  # A parent directory shorter than this is too general to count as naming a
  # file: `priv` would match nearly every module that reads anything.
  @min_named_segments 2

  @doc """
  Builds the plan for `changed` against `index`.

  `changed` are repo-relative paths as git reports them, including deletions;
  paths that no longer exist are dropped by intersecting with the index, so the
  plan can never name a file `mix test` would silently skip.

  ## Options

    * `:upstream` - `{changed, index}` for the path dependency this
      repository builds against.
    * `:upstream_tests` - a directory of this repository's tests that any
      upstream change reaching the build selects in full.
  """
  @spec plan([String.t()], index(), keyword()) :: plan()
  def plan(changed, index, opts \\ []) do
    changed
    |> accumulate(index)
    |> apply_upstream(Keyword.get(opts, :upstream), Keyword.get(opts, :upstream_tests), index)
    |> finalise(index)
  end

  defp accumulate(changed, index) do
    changed
    |> Enum.map(&classify/1)
    |> Enum.map(&collapse/1)
    |> Enum.uniq()
    |> Enum.reduce(empty_plan(), &apply_classification(&1, &2, index))
  end

  # One catalogue reaches what every catalogue does, and an extraction touches
  # dozens at once, so they are resolved as a single change.
  defp collapse({:translations, _path}),
    do: {:translations, String.trim_trailing(@translation_prefix, "/")}

  defp collapse(classified), do: classified

  @doc """
  Classifies one changed path.

  `:ignore` cannot affect the Elixir suite. `:widen` is compiled into, or read
  by, every test. `:migrations` changes the database shape underneath all of
  them. `{:test, path}` is a test file in its own right, and `{:lib, path}` is
  compiled code to resolve through its mirror directory. `:tooling`,
  `:translations` and `:data` are not code, and are resolved through whoever
  names them (see the moduledoc).
  """
  @spec classify(String.t()) ::
          :ignore
          | {:widen | :migrations | :test | :lib, String.t()}
          | {:tooling | :translations | :data, String.t()}
  def classify(path) do
    cond do
      path in @widening_files -> {:widen, path}
      starts_with_any?(path, @migration_prefixes) -> {:migrations, path}
      starts_with_any?(path, @widening_prefixes) -> {:widen, path}
      String.ends_with?(path, "_test.exs") -> {:test, path}
      starts_with_any?(path, @ignored_prefixes) -> :ignore
      Path.extname(path) in @ignored_extensions -> :ignore
      String.starts_with?(path, @translation_prefix) -> {:translations, path}
      starts_with_any?(path, @source_prefixes) and compiled?(path) -> {:lib, path}
      tooling?(path) -> {:tooling, path}
      true -> {:data, path}
    end
  end

  defp compiled?(path), do: Enum.any?(@source_extensions, &String.ends_with?(path, &1))

  defp tooling?(path) do
    name = Path.basename(path)

    name in @tooling_files or name =~ @tooling_names or
      starts_with_any?(path, @tooling_prefixes)
  end

  # Maps a lib path to the deepest existing mirror test directory.
  #
  # `lib/tymeslot/auth/oauth/google.ex` mirrors to `test/tymeslot/auth/oauth`,
  # walking up a segment at a time when a directory has no counterpart. Around a
  # third of lib directories do not mirror exactly, so the walk matters; it stops
  # at `test/` rather than selecting the whole suite by accident.
  @spec mirror_dir(String.t(), index()) :: String.t() | nil
  defp mirror_dir(path, index) do
    path
    |> Path.dirname()
    |> test_dir()
    |> walk_up(index)
  end

  defp test_dir("lib/" <> rest), do: "test/" <> rest
  defp test_dir("dev_support/" <> rest), do: "test/dev_support/" <> rest
  defp test_dir(path), do: path

  defp walk_up("test", _index), do: nil
  defp walk_up(".", _index), do: nil

  defp walk_up(dir, index) when is_binary(dir) do
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

  defp apply_classification({:translations, path}, plan, index) do
    tags = MapSet.intersection(MapSet.new([@translation_tag]), index.domain_tags)

    plan
    |> add_tagged(tags, index, "#{path}: #{describe_tags(tags)}")
    |> apply_named(path, index, fn plan -> plan end)
  end

  defp apply_classification({:tooling, path}, plan, index),
    do: apply_named(plan, path, index, fn plan -> plan end)

  defp apply_classification({:data, path}, plan, index) do
    unnamed = fn plan ->
      %{
        plan
        | scope: :full_suite,
          reasons: ["#{path}: not named by any test or module" | plan.reasons]
      }
    end

    apply_named(plan, path, index, unnamed)
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

  # Runs the tests that name `path`, plus the mirror tests of each module that
  # does; `unnamed` decides what a path nobody names does. The module's own code
  # did not change, so its domain is not swept: that is the rule for code, and
  # here it would turn one module reading a file into half the suite. A
  # test-support module reaches the tests that use it rather than widening, as
  # changing it would.
  defp apply_named(plan, path, index, unnamed) do
    {tests, modules} = named_by(path, index)
    {support, modules} = Enum.split_with(modules, &String.starts_with?(&1, "test/support/"))
    tests = tests ++ Enum.flat_map(support, &users_of(&1, index))

    if tests == [] and modules == [] do
      unnamed.(plan)
    else
      plan = %{
        plan
        | files: union(plan.files, tests),
          reasons: ["#{path}: named by #{describe_named(tests, modules)}" | plan.reasons]
      }

      Enum.reduce(modules, plan, &apply_reader(&1, &2, index))
    end
  end

  defp apply_reader(module, plan, index) do
    case mirror(module, index) do
      nil ->
        %{
          plan
          | scope: :full_suite,
            reasons: ["#{module}: reads a changed file and has no mirror test" | plan.reasons]
        }

      {seed, _label} ->
        %{plan | files: union(plan.files, seed)}
    end
  end

  # The test files naming any module `file` defines.
  defp users_of(file, index) do
    case @defmodule_re |> Regex.scan(Map.fetch!(index.sources, file)) |> Enum.map(&List.last/1) do
      [] ->
        []

      names ->
        pattern = :binary.compile_pattern(names)
        Enum.filter(index.test_files, &contains?(Map.get(index.sources, &1, ""), pattern))
    end
  end

  defp contains?(source, pattern), do: :binary.match(source, pattern) != :nomatch

  defp named_by(path, index) do
    pattern = path |> needles() |> :binary.compile_pattern()

    index.sources
    |> Enum.filter(fn {file, source} -> file != path and contains?(source, pattern) end)
    |> Enum.map(fn {file, _source} -> file end)
    |> Enum.sort()
    |> Enum.split_with(&MapSet.member?(index.test_files, &1))
  end

  # The path itself, and each parent directory long enough to be specific.
  defp needles(path) do
    segments = Path.split(path)

    (length(segments) - 1)..@min_named_segments//-1
    |> Enum.map(&(segments |> Enum.take(&1) |> Path.join()))
    |> then(&[path | &1])
  end

  defp describe_named(tests, modules) do
    [{tests, "test file"}, {modules, "module"}]
    |> Enum.reject(fn {list, _noun} -> list == [] end)
    |> Enum.map_join(" and ", fn {list, noun} ->
      "#{length(list)} #{noun}#{if length(list) == 1, do: "", else: "s"}"
    end)
  end

  defp add_tagged(plan, tags, index, reason) do
    tagged = Enum.filter(index.test_files, &tagged_with_any?(&1, tags, index))

    %{
      plan
      | files: union(plan.files, tagged),
        tags: MapSet.union(plan.tags, tags),
        reasons: [reason | plan.reasons]
    }
  end

  defp apply_upstream(plan, nil, _upstream_tests, _index), do: plan

  defp apply_upstream(plan, {changed, upstream_index}, upstream_tests, index) do
    reaching = Enum.reject(changed, &(classify(&1) == :ignore))
    upstream = accumulate(reaching, upstream_index)
    reasons = Enum.map(Enum.reverse(upstream.reasons), &"upstream #{&1}")

    cond do
      reaching == [] ->
        plan

      upstream.scope == :full_suite ->
        %{plan | scope: :full_suite, reasons: Enum.reverse(reasons) ++ plan.reasons}

      true ->
        plan
        |> add_tagged(upstream.tags, index, upstream_summary(reaching, upstream.tags))
        |> add_own_domains(reaching, upstream_index, index)
        |> add_upstream_tests(upstream_tests, index)
    end
  end

  # The tag sweep only crosses domains both suites share, so a domain no
  # upstream test carries (marketing, billing, legal) can never be reached by
  # it, though its tests render and wrap upstream code all the same. Any
  # upstream change that reaches code selects those domains whole. An upstream
  # test file reaches no code, so it is left to the cross-checks.
  defp add_own_domains(plan, reaching, upstream_index, index) do
    own = MapSet.difference(domain_tags_in(index), domain_tags_in(upstream_index))

    if Enum.all?(reaching, &match?({:test, _}, classify(&1))) or Enum.empty?(own) do
      plan
    else
      add_tagged(
        plan,
        own,
        index,
        "upstream: domains no upstream test carries: #{describe_tags(own)}"
      )
    end
  end

  defp domain_tags_in(index) do
    index.tags
    |> Map.values()
    |> Enum.reduce(MapSet.new(), &MapSet.union/2)
    |> MapSet.intersection(index.domain_tags)
  end

  defp upstream_summary(changed, tags) do
    count = length(changed)
    "#{count} upstream #{if count == 1, do: "change", else: "changes"}: #{describe_tags(tags)}"
  end

  defp add_upstream_tests(plan, nil, _index), do: plan

  defp add_upstream_tests(plan, dir, index) do
    dir = String.trim_trailing(dir, "/")
    files = Enum.filter(index.test_files, &in_dir?(&1, dir))

    %{
      plan
      | files: union(plan.files, files),
        reasons: ["#{dir}/: checks the upstream" | plan.reasons]
    }
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
      |> test_dir()
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
        Enum.map_join(list, ", ", &inspect/1)

      list ->
        "#{Enum.map_join(Enum.take(list, @tags_shown), ", ", &inspect/1)} and #{length(list) - @tags_shown} more"
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

  @doc """
  Reads the domain tags a test module declares, from its source.

  Both forms the `CredoChecks.TestModuleTagRequired` check accepts are read:
  `@moduletag :auth` and `@moduletag backup_tests: true`. Matching by string
  against the taxonomy, rather than converting whatever is found into an atom,
  means an unknown tag is simply not a domain tag: no atom is created from file
  contents, and there is no failure to swallow. Tags outside the `domain`
  category are dropped because nothing selects on them.
  """
  @spec tags_in_source(String.t(), MapSet.t(atom())) :: MapSet.t(atom())
  def tags_in_source(source, domain_tags) do
    code = String.replace(source, @heredoc_re, "")
    found = MapSet.new(Regex.scan(@moduletag_re, code), fn [_line, tag] -> tag end)

    domain_tags
    |> Enum.filter(&MapSet.member?(found, Atom.to_string(&1)))
    |> MapSet.new()
  end

  @doc "Formats a count as a percentage of the suite, for reporting."
  @spec percent(non_neg_integer(), pos_integer()) :: String.t()
  def percent(count, total), do: "#{round(count / total * 100)}%"

  defp starts_with_any?(path, prefixes), do: Enum.any?(prefixes, &String.starts_with?(path, &1))
end
