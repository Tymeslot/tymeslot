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
  # consumed by the regulator in `dialyzer_coordinator`), so its peak memory is
  # a function of the host's core count rather than of project size. On a
  # 16-core machine that is sixteen concurrent workers each holding module
  # code, callgraph slices and inferred types, measured at roughly 13G, which
  # is enough for systemd-oomd to start killing desktop applications.
  #
  # Capping schedulers makes dialyzer *use* less, where a memory cap alone only
  # makes it thrash or get killed once it has already asked for too much. The
  # cap is keyed off the command rather than the step's display name, and set
  # here rather than for the run as a whole, so the test suite in the same
  # `mix precommit` keeps every core. `MIX_DIALYZER_SCHEDULERS` overrides it,
  # matching the flag of the same name in the workspace `mix.sh`.
  @doc false
  @spec step_env([String.t()]) :: [{String.t(), String.t()}]
  def step_env(["dialyzer" | _rest]) do
    schedulers = System.get_env("MIX_DIALYZER_SCHEDULERS", "4")
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
