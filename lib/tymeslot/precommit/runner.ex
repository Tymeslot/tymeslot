defmodule Tymeslot.Precommit.Runner do
  @moduledoc """
  Shared engine behind `mix precommit` and `mix saas.precommit`.

  Runs a list of `{name, args, env}` steps, keeps going after a failure so a
  single run reports everything that needs fixing, and prints a summary. The
  one exception is compilation: any step named "compile" (or a variant, such
  as a second compile in a different `MIX_ENV`) is a barrier: if it fails,
  downstream steps would only report noise, so the run stops there.

  ## Why the suite runs alongside the rest

  The suite is the longest step by a wide margin and needs nothing the other
  steps produce beyond a compiled build, so run in sequence it simply adds its
  wall clock to the gate's. Once the compile barriers have passed it is started
  in the background and joined at the end, which hides the static checks behind
  it rather than queueing them after it.

  It is the suite rather than one of the static checks that goes to the
  background for two reasons. It is the long pole, so it is the one worth
  overlapping; and it is the only step running under `MIX_ENV=test`, so it
  takes a different build lock. Two `mix` invocations sharing a build path
  serialise on that lock, which would have handed back much of what the
  concurrency won.

  Its output is buffered and printed at the join, so it cannot interleave with
  the step running in the foreground. That is the cost of the arrangement: the
  suite's output arrives in one block at the end instead of scrolling live.

  `--fail-fast` turns this off and runs everything in sequence. It asks for the
  first failure as soon as possible, which is incompatible with a step whose
  result is only known at the end.
  """

  @barrier_prefix "compile"

  @type step :: {name :: String.t(), args :: [String.t()], env :: atom()}
  @type result :: {name :: String.t(), :passed | :failed | :skipped, non_neg_integer()}
  @type cmd_fun :: ([String.t()], atom() -> non_neg_integer())
  @type capture_fun :: ([String.t()], atom() -> {String.t(), non_neg_integer()})

  @spec run([step()], boolean(), keyword()) :: :ok
  def run(steps, fail_fast?, opts \\ []) do
    cmd_fun = Keyword.get(opts, :cmd, &cmd/2)
    capture_fun = Keyword.get(opts, :capture, &capture/2)
    results = run_all(steps, fail_fast?, cmd_fun, capture_fun)

    report(results)

    if Enum.any?(results, &match?({_name, :failed, _code}, &1)) do
      exit({:shutdown, 1})
    end

    :ok
  end

  # `--fail-fast` keeps the plain sequential path: a run that stops at the first
  # failure cannot also be waiting on a step that only reports at the end.
  defp run_all(steps, true, cmd_fun, _capture_fun), do: run_steps(steps, true, cmd_fun, [])

  defp run_all(steps, false, cmd_fun, capture_fun) do
    {head, tail} = split_after_last_barrier(steps)
    {backgrounded, tail} = Enum.split_with(tail, &background?/1)
    head_results = run_steps(head, false, cmd_fun, [])

    if broken?(head_results) do
      head_results
    else
      # Started here rather than at the top of the run because the suite needs
      # the beams the compile steps produce, and a build that does not compile
      # is the case those barriers exist to stop.
      tasks = Enum.map(backgrounded, &start_background(&1, capture_fun))
      results = head_results ++ run_steps(tail, false, cmd_fun, []) ++ Enum.map(tasks, &join/1)
      order_like(steps, results)
    end
  end

  # The summary reads as the gate's running order, not as the order results
  # happened to arrive, so a backgrounded step keeps its declared position.
  defp order_like(steps, results) do
    by_name = Map.new(results, fn {name, _status, _code} = result -> {name, result} end)

    Enum.flat_map(steps, fn {name, _args, _env} ->
      case Map.fetch(by_name, name) do
        {:ok, result} -> [result]
        :error -> []
      end
    end)
  end

  defp start_background({name, args, env}, capture_fun) do
    Mix.shell().info([
      :bright,
      "\n==> #{name}",
      :reset,
      :faint,
      "  mix #{Enum.join(args, " ")}  (in the background; output follows at the end)"
    ])

    {name, Task.async(fn -> capture_fun.(args, env) end)}
  end

  # No timeout: the step takes as long as it takes, and a run that has already
  # spent minutes on the static checks should not throw away a nearly finished
  # suite over a deadline nobody could set correctly.
  defp join({name, task}) do
    {output, code} = Task.await(task, :infinity)

    Mix.shell().info([:bright, "\n==> #{name}", :reset, :faint, "  (background output)"])
    IO.write(output)

    if code == 0, do: {name, :passed, 0}, else: {name, :failed, code}
  end

  # Everything up to and including the last barrier runs in the foreground, so
  # a backgrounded step can never start against a build the gate has not yet
  # established.
  defp split_after_last_barrier(steps) do
    case Enum.find_index(Enum.reverse(steps), fn {name, _args, _env} -> barrier?(name) end) do
      nil -> {[], steps}
      offset -> Enum.split(steps, length(steps) - offset)
    end
  end

  # Keyed off the command rather than the step's display name, matching
  # `step_env/1`: the name is a label and can be reworded, the command is the
  # contract.
  defp background?({_name, ["test" | _rest], _env}), do: true
  defp background?(_step), do: false

  defp broken?(results), do: Enum.any?(results, &match?({_name, :skipped, _code}, &1))

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
  # The background counterpart to `cmd/2`: the same invocation, with the output
  # collected rather than streamed so it can be printed in one block at the join.
  defp capture(args, env) do
    System.cmd("mix", args,
      stderr_to_stdout: true,
      env: [{"MIX_ENV", to_string(env)} | step_env(args)]
    )
  end

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
