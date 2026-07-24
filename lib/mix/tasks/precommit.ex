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
  so.

  A hard compile error never reaches that check: Mix has to compile the project
  to load this task at all, so it aborts first and prints the error on its own.
  Same information, one step earlier.

  ## Why each step is a separate process

  Mix resolves `MIX_ENV` once, from the invoked task. The suite has to run in
  `:test` while dialyzer needs `:dev`, where dialyxir is declared and where the
  PLT is cached, so no single environment covers the whole gate. Shelling out
  gives each step the environment it needs and an honest exit code, at the cost
  of about a second of Mix boot per step.
  """

  use Mix.Task

  @steps [
    {"format", ~w[format --check-formatted], :dev},
    {"deps.unlock", ~w[deps.unlock --check-unused], :dev},
    {"compile", ~w[compile --warnings-as-errors], :dev},
    {"credo", ~w[credo --strict], :dev},
    {"sobelow", ~w[sobelow], :dev},
    {"deps.audit", ~w[deps.audit], :dev},
    {"migrations", ~w[excellent_migrations.check_safety], :dev},
    {"xref", ~w[xref graph --label compile-connected --fail-above 25], :dev},
    {"test", ~w[test], :test},
    {"dialyzer", ~w[dialyzer], :dev}
  ]

  # Everything after this step depends on a working build, so a failure here
  # ends the run rather than producing several pages of downstream noise.
  @barrier "compile"

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: [fail_fast: :boolean])
    fail_fast? = Keyword.get(opts, :fail_fast, false)

    results = run_steps(@steps, fail_fast?, [])

    report(results)

    if Enum.any?(results, &match?({_name, :failed, _code}, &1)) do
      exit({:shutdown, 1})
    end
  end

  defp run_steps([], _fail_fast?, acc), do: Enum.reverse(acc)

  defp run_steps([{name, args, env} | rest], fail_fast?, acc) do
    Mix.shell().info([:bright, "\n==> #{name}", :reset, :faint, "  mix #{Enum.join(args, " ")}"])

    result =
      case cmd(args, env) do
        0 -> {name, :passed, 0}
        code -> {name, :failed, code}
      end

    acc = [result | acc]

    cond do
      match?({_step, :passed, _code}, result) -> run_steps(rest, fail_fast?, acc)
      name == @barrier -> Enum.reverse([{"(skipped)", :skipped, 0} | acc])
      fail_fast? -> Enum.reverse(acc)
      true -> run_steps(rest, fail_fast?, acc)
    end
  end

  defp cmd(args, env) do
    {_output, code} =
      System.cmd("mix", args,
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true,
        env: [{"MIX_ENV", to_string(env)}]
      )

    code
  end

  defp report(results) do
    Mix.shell().info([:bright, "\nSummary", :reset])

    Enum.each(results, fn
      {name, :passed, _code} ->
        Mix.shell().info(["  ", :green, "ok      ", :reset, name])

      {name, :failed, code} ->
        Mix.shell().info(["  ", :red, "failed  ", :reset, "#{name} (#{code})"])

      {_name, :skipped, _code} ->
        Mix.shell().info(["  ", :faint, "skipped remaining steps: the build is broken", :reset])
    end)
  end
end
