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
    * **deps.unlock, deps.audit, sobelow, migrations and workflows** run only
      when the diff touches the files they read.
    * **The suite** is narrowed by `Tymeslot.TestAffected.Selection`, the engine
      behind `mix test.affected`, and inherits its rule of widening to the full
      suite rather than guessing.

  ## Changes upstream

  The repository that consumes Core as a path dependency cannot see a Core
  change in its own diff, yet its build and suite run against it. The caller
  therefore passes the path dependency's changes as `:upstream`. Any of them
  that reaches the Elixir build keeps the static steps running and takes the
  full suite, because no path in this repository resolves to what a Core change
  affects here.

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
          suite: Selection.plan() | :upstream
        }

  @dep_files ~w[mix.exs mix.lock]
  @workflow_prefixes ~w[.github/workflows/ .gitea/workflows/]
  @migration_prefixes ~w[priv/repo/migrations/ priv/saas_repo/migrations/]

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
    "sobelow" => {:security, "no web, config, auth or upload code changed"},
    "excellent_migrations.check_safety" => {:migrations, "no migration changed"},
    "actionlint" => {:workflows, "no workflow changed"}
  }

  @doc """
  Narrows `steps` against the working tree, printing what it chose and why.

  `:base` widens the diff to every commit since the branch left it, as for
  `mix test.affected --base`. `:upstream_dir` is the checkout of the path
  dependency whose changes this repository builds against, if any.
  """
  @spec narrow([Runner.step()], keyword()) :: t()
  def narrow(steps, opts) do
    base = Keyword.get(opts, :base)
    changed = Workspace.changed_files(base)
    upstream = upstream_changes(Keyword.get(opts, :upstream_dir), base)
    narrowed = select(steps, changed, Workspace.index(), upstream: upstream)

    report(changed, upstream, narrowed.suite)
    narrowed
  end

  defp upstream_changes(nil, _base), do: []
  defp upstream_changes(dir, base), do: Workspace.changed_files(base, dir)

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

  defp describe_suite(:upstream),
    do: "full, because Core changed and this repository's diff cannot show what that affects"

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
  changed paths and defaults to none.
  """
  @spec select([Runner.step()], [String.t()], Selection.index(), keyword()) :: t()
  def select(steps, changed, index, opts \\ []) do
    upstream = Keyword.get(opts, :upstream, [])
    build_changed? = Enum.any?(changed ++ upstream, &reaches_build?/1)
    suite = suite(changed, upstream, index)

    {kept, skipped} =
      Enum.reduce(steps, {[], []}, fn step, {kept, skipped} ->
        case decide(step, changed, build_changed?, suite) do
          {:run, step} -> {[step | kept], skipped}
          {:skip, reason} -> {kept, [{step_name(step), reason} | skipped]}
        end
      end)

    %{steps: Enum.reverse(kept), skipped: Enum.reverse(skipped), suite: suite}
  end

  defp decide({_name, ["test" | _rest], _env} = step, _changed, _build_changed?, suite),
    do: test_step(step, suite)

  defp decide({_name, [command | _rest], _env} = step, changed, build_changed?, _suite) do
    case Map.fetch(@conditions, command) do
      {:ok, {input, reason}} ->
        if Enum.any?(changed, &touches?(input, &1)), do: {:run, step}, else: {:skip, reason}

      :error ->
        if build_changed?, do: {:run, step}, else: {:skip, "no Elixir-relevant file changed"}
    end
  end

  defp test_step(step, :upstream), do: {:run, step}

  defp test_step(_step, %{scope: :nothing}),
    do: {:skip, "no change reaches the Elixir suite"}

  defp test_step({name, args, env}, %{scope: :full_suite, include_migrations?: true}),
    do: {:run, {name, args ++ ["--include", "migrations"], env}}

  defp test_step(step, %{scope: :full_suite}), do: {:run, step}

  defp test_step({name, args, env}, %{scope: :selection, files: files}),
    do: {:run, {name, args ++ files, env}}

  defp suite(changed, upstream, index) do
    if Enum.any?(upstream, &reaches_build?/1),
      do: :upstream,
      else: Selection.plan(changed, index)
  end

  defp reaches_build?(path), do: Selection.classify(path) != :ignore

  defp touches?(:deps, path), do: path in @dep_files
  defp touches?(:workflows, path), do: String.starts_with?(path, @workflow_prefixes)
  defp touches?(:migrations, path), do: String.starts_with?(path, @migration_prefixes)

  defp touches?(:security, path),
    do: String.starts_with?(path, @security_prefixes) or path =~ @security_names

  defp step_name({name, _args, _env}), do: name
end
