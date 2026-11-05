defmodule Tymeslot.Precommit.Affected do
  @moduledoc """
  Narrows the gate to the steps a diff can affect, for `mix precommit --affected`.

  The full gate is the push-time check. Before a commit, most of its steps
  cannot be affected by most diffs, and the suite is the only step that costs
  real time, so this keeps the gate's shape and drops what the diff cannot
  reach:

    * **format, both compiles, credo, gettext, xref and dialyzer** run whenever
      anything that can reach the Elixir build changed. They are seconds when
      nothing relevant moved (gettext and dialyzer skip their own work), and
      xref's input, a new `alias`, `import` or struct reference, is not visible
      from paths alone.
    * **deps.unlock, deps.audit, sobelow, migrations, workflows, css tokens
      and the JavaScript suite** run only when the diff touches the files
      they read.
    * **hex.audit** never runs: it reads the live Hex registry, not the
      diff, so no diff can tell whether its answer moved. The full gate
      runs it.
    * **The suite** is narrowed by `Tymeslot.TestAffected.Selection`, the engine
      behind `mix test.affected`, and inherits its rule of widening to the full
      suite rather than guessing.

  ## Changes upstream

  The repository that consumes Core as a path dependency cannot see a Core
  change in its own diff, yet its build and suite run against it. The caller
  therefore passes the path dependency's checkout as `:upstream_dir`. Any Core
  change that reaches the Elixir build keeps the static steps running, and the
  suite takes what `Tymeslot.TestAffected.Selection` carries over: this
  repository's tests in the domains the Core change reaches, the directory
  named by `:upstream_tests`, or the full suite when the Core change widens.

  `select/4` is pure; `narrow/2` reads git and the disk through
  `Tymeslot.TestAffected.Workspace` and prints the plan it arrived at.
  """

  alias Tymeslot.Precommit.Runner
  alias Tymeslot.TestAffected.Selection
  alias Tymeslot.TestAffected.Workspace

  @typedoc "The narrowed gate, and why each dropped step was dropped."
  @type t :: %{
          steps: [Runner.step()],
          skipped: [{name :: String.t(), reason :: String.t()}],
          suite: Selection.plan()
        }

  @dep_files ~w[mix.exs mix.lock]
  @workflow_prefixes ~w[.github/workflows/ .gitea/workflows/]
  @migration_prefixes ~w[priv/repo/migrations/ priv/saas_repo/migrations/]
  @css_prefixes ~w[assets/css/scheduling/ scripts/test_css_tokens.sh dev_support/tooling/mix/tasks/css.check_tokens.ex]

  # What Vitest reads: the sources and their tests, and the files that decide
  # which packages and settings it runs with. Stylesheets are not among them.
  @js_prefixes ~w[assets/js/ assets/vendor/]
  @js_files ~w[
    assets/package.json
    assets/package-lock.json
    assets/vitest.config.js
    assets/vitest.setup.js
  ]

  # Sobelow reads the web layer, configuration, and anything handling params,
  # uploads or auth. The last group has no single home, so it is matched by
  # name: an over-match only runs a step that takes seconds.
  @security_prefixes ~w[config/ .sobelow-conf]
  @security_names ~r/_web\/|auth|upload|security|webhook|plug|session|token/

  # Keyed off the command rather than the step's display name, matching
  # `Tymeslot.Precommit.Runner`: the name is a label, the command is the
  # contract.
  @conditions %{
    "deps.unlock" => {:deps, "mix.exs and mix.lock unchanged"},
    "deps.audit" => {:deps, "mix.exs and mix.lock unchanged"},
    "hex.audit" => {:never, "reads the live Hex registry; the full gate runs it"},
    "sobelow" => {:security, "no web, config, auth or upload code changed"},
    "excellent_migrations.check_safety" => {:migrations, "no migration changed"},
    "actionlint" => {:workflows, "no workflow changed"},
    "css.check_tokens" => {:css, "no booking-theme CSS changed"},
    "test.js" => {:js, "no JavaScript changed"}
  }

  @doc """
  Narrows `steps` against the working tree, printing what it chose and why.

  `:base` widens the diff to every commit since the branch left it, as for
  `mix test.affected --base`. `:upstream_dir` is the checkout of the path
  dependency whose changes this repository builds against, if any, and
  `:upstream_tests` the directory of this repository's tests that check the
  two against each other.
  """
  @spec narrow([Runner.step()], keyword()) :: t()
  def narrow(steps, opts) do
    base = Keyword.get(opts, :base)
    changed = Workspace.changed_files(base)
    {upstream, upstream_index} = upstream(Keyword.get(opts, :upstream_dir), base)

    narrowed =
      select(steps, changed, Workspace.index(),
        upstream: upstream,
        upstream_index: upstream_index,
        upstream_tests: Keyword.get(opts, :upstream_tests)
      )

    report(changed, upstream, narrowed.suite)
    narrowed
  end

  defp upstream(nil, _base), do: {[], nil}

  defp upstream(dir, base) do
    case Workspace.changed_files(base, dir) do
      [] -> {[], nil}
      changed -> {changed, Workspace.index(dir)}
    end
  end

  defp report(changed, upstream, suite) do
    upstream_note = if upstream == [], do: "", else: ", #{length(upstream)} in Core"

    Mix.shell().info([
      :bright,
      "precommit --affected",
      :reset,
      ": #{length(changed)} changed #{pluralise(length(changed), "file")}#{upstream_note}"
    ])

    Mix.shell().info("  suite: #{describe_suite(suite)}")
  end

  defp describe_suite(%{scope: :nothing}), do: "not run, no change reaches it"

  defp describe_suite(%{scope: :full_suite, reasons: reasons}),
    do: "full (#{Enum.join(reasons, "; ")})"

  defp describe_suite(%{scope: :selection, files: files}),
    do:
      "#{length(files)} test #{pluralise(length(files), "file")} (`mix test.affected --explain` for why)"

  defp pluralise(1, word), do: word
  defp pluralise(_count, word), do: word <> "s"

  @doc """
  Narrows `steps` to the ones `changed` can affect.

  `changed` are this repository's changed paths, `index` its suite (see
  `Tymeslot.TestAffected.Workspace`). `:upstream` lists the path dependency's
  changed paths and defaults to none; `:upstream_index` is that dependency's
  index, required when `:upstream` is not empty, and `:upstream_tests` is
  passed through to `Tymeslot.TestAffected.Selection.plan/3`.
  """
  @spec select([Runner.step()], [String.t()], Selection.index(), keyword()) :: t()
  def select(steps, changed, index, opts \\ []) do
    upstream = Keyword.get(opts, :upstream, [])
    build_changed? = Enum.any?(changed ++ upstream, &reaches_build?/1)
    suite = suite(changed, index, opts)

    {kept, skipped} =
      Enum.reduce(steps, {[], []}, fn step, {kept, skipped} ->
        case decide(step, changed, build_changed?, suite) do
          {:run, step} -> {[step | kept], skipped}
          {:skip, reason} -> {kept, [{step_name(step), reason} | skipped]}
        end
      end)

    %{steps: Enum.reverse(kept), skipped: Enum.reverse(skipped), suite: suite}
  end

  defp decide({_name, [command | _rest], _env} = step, changed, build_changed?, suite) do
    if Runner.suite?(step),
      do: test_step(step, suite),
      else: decide_static(step, command, changed, build_changed?)
  end

  defp decide_static(step, command, changed, build_changed?) do
    case Map.fetch(@conditions, command) do
      {:ok, {input, reason}} ->
        if Enum.any?(changed, &touches?(input, &1)), do: {:run, step}, else: {:skip, reason}

      :error ->
        if build_changed?, do: {:run, step}, else: {:skip, "no Elixir-relevant file changed"}
    end
  end

  defp test_step(_step, %{scope: :nothing}),
    do: {:skip, "no change reaches the Elixir suite"}

  defp test_step({name, args, env}, %{scope: :full_suite, include_migrations?: true}),
    do: {:run, {name, args ++ ["--include", "migrations"], env}}

  defp test_step(step, %{scope: :full_suite}), do: {:run, step}

  defp test_step({name, args, env}, %{scope: :selection, files: files}),
    do: {:run, {name, args ++ files, env}}

  defp suite(changed, index, opts) do
    upstream =
      case Keyword.get(opts, :upstream, []) do
        [] -> nil
        paths -> {paths, Keyword.fetch!(opts, :upstream_index)}
      end

    Selection.plan(changed, index,
      upstream: upstream,
      upstream_tests: Keyword.get(opts, :upstream_tests)
    )
  end

  defp reaches_build?(path), do: Selection.classify(path) != :ignore

  defp touches?(:never, _path), do: false
  defp touches?(:deps, path), do: path in @dep_files
  defp touches?(:workflows, path), do: String.starts_with?(path, @workflow_prefixes)
  defp touches?(:migrations, path), do: String.starts_with?(path, @migration_prefixes)
  defp touches?(:css, path), do: String.starts_with?(path, @css_prefixes)
  defp touches?(:js, path), do: String.starts_with?(path, @js_prefixes) or path in @js_files

  defp touches?(:security, path),
    do: String.starts_with?(path, @security_prefixes) or path =~ @security_names

  defp step_name({name, _args, _env}), do: name
end
