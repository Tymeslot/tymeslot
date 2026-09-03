defmodule Mix.Tasks.Precommit do
  @shortdoc "Runs the whole verification gate and reports every failure"

  @moduledoc """
  Runs the Definition of Done in one command.

      $ mix precommit
      $ mix precommit --fail-fast

  Every step remains individually runnable (`mix credo --strict`, `mix test`,
  and so on); this only removes the chance of applying the gate by halves.
  Run `./mix.sh precommit` from the workspace root to cover both repositories.

  ## Why every step runs

  A `mix` alias is a task chain, so the first task to raise aborts the rest and
  you learn about one failure per run. This task keeps going and prints a
  summary, so a single run tells you everything that needs fixing.

  The one exception is compilation. If `--warnings-as-errors` fails, credo, the
  tests and dialyzer would only report noise, so the run stops there and says
  so. This gate compiles twice, once per `MIX_ENV`: `:dev` first, then `:test`,
  since `elixirc_paths(:test)` additionally compiles `test/support` and CI
  compiles under a job-wide `MIX_ENV=test`. A warning confined to test-support
  code would otherwise pass here and only fail in CI. Both compile steps are
  barriers, for the same reason.

  A hard compile error never reaches that check: Mix has to compile the project
  to load this task at all, so it aborts first and prints the error on its own.
  Same information, one step earlier.

  ## Why dialyzer runs incrementally

  The step runs `dialyzer.incremental`, not `dialyzer`. A classic PLT is
  re-verified wholesale whenever dialyxir's `mix.lock`-and-applications hash
  moves, and re-analysed wholesale on every run regardless; an incremental PLT
  tracks per-module hashes and re-analyses only what changed. Measured here,
  with nothing changed since the previous run: 78.7s against 4.5s in Core, and
  451.8s against 12.0s in the repo that consumes Core as a path dependency,
  where every Core commit invalidates the classic PLT.

  The two modes were adopted on identical output: the same warnings, the same
  skips, the same exit status, verified both on a clean tree and against a
  deliberately broken `@spec`. `mix dialyzer` is unchanged and remains the
  cross-check to run when a warning here looks wrong. `--list-unused-filters`
  is passed explicitly because the incremental task takes it as an argument
  rather than reading `:list_unused_filters` from the `dialyzer:` config.

  ## Why each step is a separate process

  Mix resolves `MIX_ENV` once, from the invoked task. The suite has to run in
  `:test` while dialyzer needs `:dev`, where dialyxir is declared and where the
  PLT is cached, so no single environment covers the whole gate. Shelling out
  gives each step the environment it needs and an honest exit code, at the cost
  of about a second of Mix boot per step.
  """

  use Mix.Task

  alias Tymeslot.Precommit.Runner

  @steps [
    {"format", ~w[format --check-formatted], :dev},
    {"deps.unlock", ~w[deps.unlock --check-unused], :dev},
    {"compile", ~w[compile --warnings-as-errors], :dev},
    {"compile (test)", ~w[compile --warnings-as-errors], :test},
    # Catches user-facing copy that was written but never extracted. Nothing
    # else does: `GettextCompletenessTest` compares the `.po` catalogues
    # against the `.pot` templates, so a template that is itself stale looks
    # complete to it, and a whole feature's strings can reach a release
    # English-only in every other locale. It sits here because it is a compile
    # (the extractor is a compiler pass), so it belongs behind the two compile
    # barriers and in front of the steps that only read the build.
    {"gettext", ~w[gettext.extract --check-up-to-date], :dev},
    {"credo", ~w[credo --strict], :dev},
    {"sobelow", ~w[sobelow], :dev},
    {"deps.audit", ~w[deps.audit], :dev},
    {"migrations", ~w[excellent_migrations.check_safety], :dev},
    {"workflows", ~w[actionlint], :dev},
    {"xref", ~w[xref graph --label compile-connected --fail-above 25], :dev},
    {"test", ~w[test], :test},
    {"dialyzer", ~w[dialyzer.incremental --list-unused-filters], :dev}
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: [fail_fast: :boolean])
    fail_fast? = Keyword.get(opts, :fail_fast, false)

    Runner.run(@steps, fail_fast?)
  end
end
