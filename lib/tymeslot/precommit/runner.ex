defmodule Tymeslot.Precommit.Runner do
  @moduledoc """
  Shared engine behind `mix precommit` and `mix saas.precommit`.

  Runs a list of `{name, args, env}` steps, keeps going after a failure so a
  single run reports everything that needs fixing, and prints a summary. The
  one exception is compilation: any step named "compile" (or a variant, such
  as a second compile in a different `MIX_ENV`) is a barrier: if it fails,
  downstream steps would only report noise, so the run stops there.
  """

  @barrier_prefix "compile"

  @type step :: {name :: String.t(), args :: [String.t()], env :: atom()}
  @type cmd_fun :: ([String.t()], atom() -> non_neg_integer())

  @spec run([step()], boolean(), keyword()) :: :ok
  def run(steps, fail_fast?, opts \\ []) do
    cmd_fun = Keyword.get(opts, :cmd, &cmd/2)
    results = run_steps(steps, fail_fast?, cmd_fun, [])

    report(results)

    if Enum.any?(results, &match?({_name, :failed, _code}, &1)) do
      exit({:shutdown, 1})
    end

    :ok
  end

  defp run_steps([], _fail_fast?, _cmd_fun, acc), do: Enum.reverse(acc)

  defp run_steps([{name, args, env} | rest], fail_fast?, cmd_fun, acc) do
    Mix.shell().info([:bright, "\n==> #{name}", :reset, :faint, "  mix #{Enum.join(args, " ")}"])

    result =
      case cmd_fun.(args, env) do
        0 -> {name, :passed, 0}
        code -> {name, :failed, code}
      end

    acc = [result | acc]

    cond do
      match?({_step, :passed, _code}, result) -> run_steps(rest, fail_fast?, cmd_fun, acc)
      barrier?(name) -> Enum.reverse([{"(skipped)", :skipped, 0} | acc])
      fail_fast? -> Enum.reverse(acc)
      true -> run_steps(rest, fail_fast?, cmd_fun, acc)
    end
  end

  defp barrier?(name), do: String.starts_with?(name, @barrier_prefix)

  defp cmd(args, env) do
    {_output, code} =
      System.cmd("mix", args,
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true,
        env: [{"MIX_ENV", to_string(env)} | step_env(args)]
      )

    code
  end

  # Dialyzer sizes its analysis worker pool to
  # `erlang:system_info(schedulers_online)` (`dialyzer_utils:parallelism/0`,
  # consumed by the regulator in `dialyzer_coordinator`), so the count decides
  # how much of the analysis runs at once.
  #
  # It was pinned to 4 as a memory guard, on a 13G figure measured while
  # building a PLT from scratch. This step does that on the days a dependency or
  # the toolchain moves and on no others; the warm run it performs the rest of
  # the time holds 4.2G to 5.4G whether it is handed 4 schedulers or 16. So the
  # number is a speed setting, and the memory guard is the systemd scope in the
  # workspace `mix.sh`, which bounds the whole process tree however much
  # dialyzer asks for. Measured on Core, three runs each, median wall clock: 92s
  # at 4, 77s at 8, 92s at 16, the last losing to coordination overhead.
  #
  # The cap is keyed off the command rather than the step's display name, and set
  # here rather than for the run as a whole, so the test suite in the same
  # `mix precommit` keeps every core. `MIX_DIALYZER_SCHEDULERS` overrides it,
  # matching the flag of the same name in the workspace `mix.sh`.
  #
  # Both task names are matched. The gate runs `dialyzer.incremental`, while
  # `dialyzer` remains available as the cross-check the incremental mode was
  # adopted against, and a cap that quietly stopped applying to either would be
  # invisible: the run would simply get slower.
  @doc false
  @spec step_env([String.t()]) :: [{String.t(), String.t()}]
  def step_env([command | _rest]) when command in ~w[dialyzer dialyzer.incremental] do
    schedulers = System.get_env("MIX_DIALYZER_SCHEDULERS", "8")
    [{"ERL_FLAGS", "+S #{schedulers}:#{schedulers}"}]
  end

  def step_env(_args), do: []

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
