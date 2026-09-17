defmodule Tymeslot.Precommit.Runner do
  @moduledoc """
  Shared engine behind `mix precommit` and `mix saas.precommit`.

  Runs a list of `{name, args, env}` steps, keeps going after a failure so a
  single run reports everything that needs fixing, and prints a summary. The
  one exception is compilation: any step named "compile" (or a variant, such
  as a second compile in a different `MIX_ENV`) is a barrier: if it fails,
  downstream steps would only report noise, so the run stops there.

  ## What runs at the same time

  Once the compile barriers have passed, nothing downstream needs anything from
  another step beyond the build they established, so run in sequence the gate
  simply adds every step's wall clock together. Instead:

    * **The suite** starts in the background straight away. It is the long pole
      and the only step under `MIX_ENV=test`, so it takes a different build lock
      from everything else and never waits on it. Given a `:suite_plan`, it is
      also split into `mix test --partitions` runs of its own (see
      *Partitioning the suite*).
    * **Steps that write the dev build** (`gettext.check`, which recompiles when
      its inputs moved) run next, one at a time in the foreground, so nothing
      reads the build while it is being rewritten.
    * **Every other step** then runs concurrently. They only read the build, or
      reach it through `mix compile`, which Mix serialises behind its build lock
      and which is a no-op by this point. Each of these is mostly Mix boot time
      plus one tool, so the group finishes in about the time of its slowest
      member, credo or dialyzer, instead of their sum.

  Output from a concurrent step is buffered and printed whole when that step
  finishes, so two steps never interleave; the suite's arrives in one block at
  the end. That is the cost of the arrangement: nothing scrolls live after the
  compile steps.

  `--fail-fast` turns all of this off and runs everything in sequence. It asks
  for the first failure as soon as possible, which is incompatible with steps
  whose results are only known when they finish together.

  ## Partitioning the suite

  Most of the suite's wall clock is its synchronous modules, which ExUnit runs
  one at a time however many cores are free. Partitions are separate OS
  processes, so they run those modules side by side. The `:suite_plan` option
  is called when the suite starts and returns how many partitions to run and how
  many schedulers each may use (see `Tymeslot.Precommit.CpuBudget`), or `nil` to
  run it whole.

  Each partition gets its own database and upload directory through
  `MIX_TEST_PARTITION`, which `mix test --partitions` requires to be the bare
  partition number. A worktree already uses that variable as its database
  suffix, so the incoming value is passed on as `MIX_TEST_PARTITION_BASE` and
  the test config joins the two: partition 3 in a worktree suffixed `_next`
  uses `tymeslot_test_next3`. The databases are created and migrated by the
  `test` alias on first use.

  A partitioned run therefore never touches the unnumbered test database, which
  is what lets another repository's suite use that one at the same time.
  """

  @barrier_prefix "compile"
  @dialyzer_schedulers 8

  @type step :: {name :: String.t(), args :: [String.t()], env :: atom()}
  @type result :: {name :: String.t(), :passed | :failed | :skipped, non_neg_integer()}
  @type cmd_fun :: ([String.t()], atom() -> non_neg_integer())
  @type capture_fun ::
          ([String.t()], atom(), [{String.t(), String.t()}] -> {String.t(), non_neg_integer()})
  @type suite_plan_fun :: (-> Tymeslot.Precommit.CpuBudget.plan() | nil)

  @spec run([step()], boolean(), keyword()) :: :ok
  def run(steps, fail_fast?, opts \\ []) do
    cmd_fun = Keyword.get(opts, :cmd, &cmd/2)
    capture_fun = Keyword.get(opts, :capture, &capture/3)
    suite_plan_fun = Keyword.get(opts, :suite_plan, fn -> nil end)
    results = run_all(steps, fail_fast?, cmd_fun, {capture_fun, suite_plan_fun})

    report(results)

    if Enum.any?(results, &match?({_name, :failed, _code}, &1)) do
      exit({:shutdown, 1})
    end

    :ok
  end

  # `--fail-fast` keeps the plain sequential path: a run that stops at the first
  # failure cannot also be waiting on a step that only reports at the end.
  defp run_all(steps, true, cmd_fun, _background), do: run_steps(steps, true, cmd_fun, [])

  defp run_all(steps, false, cmd_fun, {capture_fun, suite_plan_fun}) do
    {head, tail} = split_after_last_barrier(steps)
    head_results = run_steps(head, false, cmd_fun, [])

    if broken?(head_results) do
      head_results
    else
      {backgrounded, tail} = Enum.split_with(tail, &background?/1)

      # Started here rather than at the top of the run because the suite needs
      # the beams the compile steps produce, and a build that does not compile
      # is the case those barriers exist to stop.
      tasks = Enum.map(backgrounded, &start_background(&1, capture_fun, suite_plan_fun))
      tail_results = run_tail(head, tail, cmd_fun, capture_fun)

      order_like(steps, head_results ++ tail_results ++ Enum.map(tasks, &join/1))
    end
  end

  # Overlapping the static checks is only safe against a build the gate has
  # established, so a step list without a compile barrier keeps them in
  # sequence.
  defp run_tail([], tail, cmd_fun, _capture_fun), do: run_steps(tail, false, cmd_fun, [])

  defp run_tail(_head, tail, cmd_fun, capture_fun) do
    {writers, readers} = Enum.split_with(tail, &writes_build?/1)
    run_steps(writers, false, cmd_fun, []) ++ run_concurrently(readers, capture_fun)
  end

  # Each step's output is printed as it finishes rather than in declared order,
  # so a fast failure is on screen while credo and dialyzer are still running.
  # Printing happens here, in the calling process, which is what keeps two
  # steps' blocks from interleaving.
  defp run_concurrently([], _capture_fun), do: []

  defp run_concurrently(steps, capture_fun) do
    names = Enum.map_join(steps, ", ", fn {name, _args, _env} -> name end)

    Mix.shell().info([
      :bright,
      "\n==> #{names}",
      :reset,
      :faint,
      "  (concurrently; each step's output follows as it finishes)"
    ])

    steps
    |> Task.async_stream(fn {name, args, env} -> {name, args, capture_fun.(args, env, [])} end,
      max_concurrency: length(steps),
      ordered: false,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, {name, args, {output, code}}} ->
      Mix.shell().info([
        :bright,
        "\n==> #{name}",
        :reset,
        :faint,
        "  mix #{Enum.join(args, " ")}"
      ])

      IO.write(output)
      status(name, code)
    end)
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

  defp start_background({name, args, env}, capture_fun, suite_plan_fun) do
    plan = suite_plan_fun.()

    Mix.shell().info([
      :bright,
      "\n==> #{name}",
      :reset,
      :faint,
      "  mix #{Enum.join(args, " ")}  (#{describe_plan(plan)}in the background; output follows at the end)"
    ])

    {name, Task.async(fn -> capture_suite(args, env, capture_fun, plan) end)}
  end

  defp describe_plan(nil), do: ""

  defp describe_plan(%{partitions: 1, schedulers: schedulers}),
    do: "1 partition of #{schedulers} schedulers, "

  defp describe_plan(%{partitions: partitions, schedulers: schedulers}),
    do: "#{partitions} partitions of #{schedulers} schedulers each, "

  defp capture_suite(args, env, capture_fun, nil), do: capture_fun.(args, env, [])

  defp capture_suite(args, env, capture_fun, %{partitions: count, schedulers: schedulers}) do
    base = System.get_env("MIX_TEST_PARTITION", "")
    erl_flags = String.trim("#{System.get_env("ERL_FLAGS")} +S #{schedulers}:#{schedulers}")
    partition_args = args ++ ["--partitions", Integer.to_string(count)]

    1..count
    |> Task.async_stream(
      fn index ->
        capture_fun.(partition_args, env, [
          {"MIX_TEST_PARTITION", Integer.to_string(index)},
          {"MIX_TEST_PARTITION_BASE", base},
          {"ERL_FLAGS", erl_flags}
        ])
      end,
      max_concurrency: count,
      timeout: :infinity
    )
    |> Enum.with_index(1)
    |> Enum.reduce({[], 0}, fn {{:ok, {output, code}}, index}, {outputs, worst} ->
      header = "\n--- partition #{index} of #{count} ---\n"
      {[outputs, header, output], if(worst == 0, do: code, else: worst)}
    end)
    |> then(fn {outputs, code} -> {IO.iodata_to_binary(outputs), code} end)
  end

  # No timeout: the step takes as long as it takes, and a run that has already
  # spent minutes on the static checks should not throw away a nearly finished
  # suite over a deadline nobody could set correctly.
  defp join({name, task}) do
    {output, code} = Task.await(task, :infinity)

    Mix.shell().info([:bright, "\n==> #{name}", :reset, :faint, "  (background output)"])
    IO.write(output)

    status(name, code)
  end

  defp status(name, 0), do: {name, :passed, 0}
  defp status(name, code), do: {name, :failed, code}

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

  # Steps that can rewrite `_build/dev` and so must not overlap the steps that
  # read it. Keyed off the command for the same reason as `background?/1`.
  defp writes_build?({_name, ["gettext.check" | _rest], _env}), do: true
  defp writes_build?(_step), do: false

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

  # The concurrent counterpart to `cmd/2`: the same invocation, with the output
  # collected rather than streamed so it can be printed in one block when the
  # step finishes.
  defp capture(args, env, extra_env) do
    System.cmd("mix", args,
      stderr_to_stdout: true,
      env: [{"MIX_ENV", to_string(env)} | step_env(args)] ++ extra_env
    )
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
  # dialyzer asks for. Measured on Core on a 16-core host, three runs each,
  # median wall clock: 92s at 4, 77s at 8, 92s at 16, the last losing to
  # coordination overhead. The cap is never more than the cores the run may use
  # (`System.schedulers_online/0`, which honours a CPU quota), so a smaller
  # machine is not handed more schedulers than it has.
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
    schedulers =
      System.get_env("MIX_DIALYZER_SCHEDULERS") ||
        Integer.to_string(dialyzer_schedulers(System.schedulers_online()))

    [{"ERL_FLAGS", "+S #{schedulers}:#{schedulers}"}]
  end

  def step_env(_args), do: []

  @doc false
  @spec dialyzer_schedulers(pos_integer()) :: pos_integer()
  def dialyzer_schedulers(cores), do: min(@dialyzer_schedulers, cores)

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
