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

  ## Code nothing mirrors

  A lib file with no mirror test file is resolved through the code that names
  its modules: the tests that do, the mirror test file of each lib module that
  does (its callers, one hop), and the files of its mirror directory, with the
  domain tags of the first two swept as for a mirror file. When neither
  exists, the mirror directory's files run alone. Its tags are never swept:
  `test/tymeslot_web/live/dashboard/` carries nearly every domain, so sweeping
  them, as this once did, turned any dashboard component into the full suite.
  Replayed over 200 commits, dropping that sweep cost no test the commits
  themselves edited. Only with no mirror directory either does the suite
  widen.

  ## Test support

  A module under `test/support/` selects the tests that reach it, and widens
  where it runs suite-wide; `Tymeslot.TestAffected.Naming` has the rules, and
  how a module is found by name.

  ## Changes upstream

  A repository consuming another as a path dependency builds against that
  dependency's working tree, which its own diff cannot show. `plan/3` takes
  those changes as `:upstream` and resolves them against the dependency's own
  index, then carries over what the two suites share: the domain tags. Tests
  in a domain no upstream test carries (the consumer's own features, which
  wrap upstream code but which no upstream tag can name) are selected whole by
  any upstream change that reaches code, since the tag sweep cannot reach
  them. A widening upstream change widens here too, and so does an upstream
  `test/support/` module, which the consumer compiles into its own suite; an
  upstream test file changes nothing here. The consumer can also name a directory of its own
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

  alias Tymeslot.TestAffected.Mirror
  alias Tymeslot.TestAffected.Naming

  @typedoc "Index of the suite as it exists on disk."
  @type index :: %{
          test_files: MapSet.t(String.t()),
          tags: %{String.t() => MapSet.t(atom())},
          domain_tags: MapSet.t(atom()),
          sources: %{String.t() => String.t()},
          config: %{String.t() => String.t()}
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

  @ignored_prefixes ~w[assets/ priv/static/ priv/cert/ .github/ .gitea/ doc/ dev/]
  @ignored_extensions ~w[.md .txt .json .yml .yaml .css .js .mjs .cjs .png .svg .ico]

  @widening_files ~w[mix.exs mix.lock]
  @widening_prefixes ~w[config/ test/test_helper.exs]
  @support_prefix "test/support/"
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
  them. `{:test, path}` is a test file in its own right, `{:lib, path}` is
  compiled code to resolve through its mirror directory, and `{:support,
  path}` is test-support code, resolved through the tests that use it.
  `:tooling`, `:translations` and `:data` are not code, and are resolved
  through whoever names them (see the moduledoc). Anything else under
  `test/support/` (fixture files, SQL) is data whatever its extension, since
  the suite reads it.
  """
  @spec classify(String.t()) ::
          :ignore
          | {:widen | :migrations | :test | :lib | :support, String.t()}
          | {:tooling | :translations | :data, String.t()}
  def classify(path) do
    cond do
      path in @widening_files -> {:widen, path}
      starts_with_any?(path, @migration_prefixes) -> {:migrations, path}
      starts_with_any?(path, @widening_prefixes) -> {:widen, path}
      String.ends_with?(path, "_test.exs") -> {:test, path}
      String.starts_with?(path, @support_prefix) -> classify_support(path)
      starts_with_any?(path, @ignored_prefixes) -> :ignore
      Path.extname(path) in @ignored_extensions -> :ignore
      String.starts_with?(path, @translation_prefix) -> {:translations, path}
      starts_with_any?(path, @source_prefixes) and compiled?(path) -> {:lib, path}
      tooling?(path) -> {:tooling, path}
      true -> {:data, path}
    end
  end

  defp classify_support(path),
    do: if(Path.extname(path) == ".ex", do: {:support, path}, else: {:data, path})

  defp compiled?(path), do: Enum.any?(@source_extensions, &String.ends_with?(path, &1))

  defp tooling?(path) do
    name = Path.basename(path)

    name in @tooling_files or name =~ @tooling_names or
      starts_with_any?(path, @tooling_prefixes)
  end

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

  defp apply_classification({:support, path}, plan, index) do
    case Naming.support_users(path, index) do
      {:widen, why} ->
        %{plan | scope: :full_suite, reasons: ["#{path}: #{why}" | plan.reasons]}

      {:ok, tests} ->
        %{
          plan
          | files: union(plan.files, tests),
            reasons: ["#{path}: used by #{count(tests, "test file")}" | plan.reasons]
        }
    end
  end

  defp apply_classification({:lib, path}, plan, index) do
    {users, callers} = Naming.code_naming(path, index)

    case Mirror.mirror_file(path, index) do
      nil -> apply_unmirrored(path, users, callers, plan, index)
      file -> add_seeded(plan, [file], users, "#{path}: #{file}", index)
    end
  end

  # Seeds the selection with `seed`, sweeps the domain tags it declares, and
  # adds `extra`, tests that name the changed module, whose tags are left out
  # of the sweep: a test naming a module is not about it.
  defp add_seeded(plan, seed, extra, label, index) do
    tags = domain_tags_of(seed, index)
    tagged = Enum.filter(index.test_files, &tagged_with_any?(&1, tags, index))
    named = if extra == [], do: "", else: " + #{count(extra, "test")} naming it"

    %{
      plan
      | files: plan.files |> union(seed) |> union(tagged) |> union(extra),
        tags: MapSet.union(plan.tags, tags),
        reasons: ["#{label} + #{describe_tags(tags)}#{named}" | plan.reasons]
    }
  end

  defp apply_unmirrored(path, [], [], plan, index) do
    case Mirror.mirror_from_dir(path, index) do
      nil ->
        %{
          plan
          | scope: :full_suite,
            reasons: ["#{path}: no mirror test file or directory" | plan.reasons]
        }

      {seed, label} ->
        %{
          plan
          | files: union(plan.files, seed),
            reasons: ["#{path}: no test or mirrored caller names it; #{label}" | plan.reasons]
        }
    end
  end

  defp apply_unmirrored(path, users, callers, plan, index) do
    caller_seeds = Enum.flat_map(callers, &List.wrap(Mirror.mirror_file(&1, index)))

    dir_files =
      case Mirror.mirror_from_dir(path, index) do
        nil -> []
        {files, _label} -> files
      end

    if users == [] and caller_seeds == [] do
      apply_unmirrored(path, [], [], plan, index)
    else
      plan
      |> add_seeded(
        caller_seeds ++ users,
        [],
        "#{path}: named by #{describe_named(users, callers)}",
        index
      )
      |> Map.update!(:files, &union(&1, dir_files))
    end
  end

  defp count(list, noun),
    do: "#{length(list)} #{noun}#{if length(list) == 1, do: "", else: "s"}"

  # Runs the tests that name `path`, plus the mirror tests of each module that
  # does; `unnamed` decides what a path nobody names does. The module's own code
  # did not change, so its domain is not swept: that is the rule for code, and
  # here it would turn one module reading a file into half the suite. A
  # test-support module reaches the tests that use it, as changing it would.
  defp apply_named(plan, path, index, unnamed) do
    {tests, modules} = Naming.named_by(path, index)
    {support, modules} = Enum.split_with(modules, &String.starts_with?(&1, @support_prefix))
    reached = Enum.map(support, &Naming.support_users(&1, index))

    case Enum.find(reached, &match?({:widen, _why}, &1)) do
      {:widen, why} ->
        %{plan | scope: :full_suite, reasons: ["#{path}: read by #{why}" | plan.reasons]}

      nil when tests == [] and modules == [] and support == [] ->
        unnamed.(plan)

      nil ->
        tests = tests ++ Enum.flat_map(reached, fn {:ok, users} -> users end)
        apply_named_found(plan, path, tests, modules, index)
    end
  end

  defp apply_named_found(plan, path, tests, modules, index) do
    if tests == [] and modules == [] do
      plan
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
    case Mirror.mirror(module, index) do
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

      # Compiled into this suite as well, where its users are this
      # repository's tests, which the upstream index cannot see.
      support = Enum.find(reaching, &match?({:support, _path}, classify(&1))) ->
        %{
          plan
          | scope: :full_suite,
            reasons: ["upstream #{support}: test support this suite compiles" | plan.reasons]
        }

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
    files = Enum.filter(index.test_files, &Mirror.in_dir?(&1, dir))

    %{
      plan
      | files: union(plan.files, files),
        reasons: ["#{dir}/: checks the upstream" | plan.reasons]
    }
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
