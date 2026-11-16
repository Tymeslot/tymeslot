defmodule Tymeslot.Precommit.Timings do
  @moduledoc """
  Records how long each `mix precommit` run and each of its steps took, and how
  much CPU the run used, one JSON line per run, so the gate's tuning can be
  judged on weeks of ordinary runs rather than on a one-off benchmark taken on
  a machine other sessions share.

  ## Where

  One file per machine, outside every checkout:
  `$XDG_STATE_HOME/tymeslot/precommit_timings.jsonl`, by default
  `~/.local/state/tymeslot/precommit_timings.jsonl`. The numbers describe a
  machine, not a branch, so every checkout and worktree on it appends to the
  same file, and each line names the checkout, branch and host it came from.
  On the herdr box `$HOME` is `/app/data`, the one writable directory that
  survives a Cloudron restart or update, so the file persists there too.

  `PRECOMMIT_TIMINGS_FILE` names another path; set empty, it turns recording
  off. Once the file passes 5 MB it is moved to `<file>.1`, replacing the
  previous one, and a new file is started.

  Each run appends its line in a single write to a file opened for appending,
  so gates finishing at the same moment cannot interleave. Recording never
  fails the gate: a run that cannot write its line says so and carries on.

  ## What a line holds

    * `wall_s`, `result`, `argv`, `repo`, `branch`, `checkout`, `host`, `at`.
    * `parallel`: the number of repos `./mix.sh -p` started together, or nil.
    * `steps`: each step's (and each test partition's) start offset from the
      beginning of the run and wall clock, so the critical path is visible.
    * `plan`: the suite's partitions and schedulers per partition.
    * `machine`: logical CPUs, the schedulers this run had, the cgroup's
      `cpu.max`, and the `ERL_FLAGS` it ran with.
    * `cpu`, in CPU-seconds:
      * `gate_s`: the gate's own VM plus every process it started for a step,
        measured from `/proc`. It works the same in a systemd scope and in a
        container, but misses what a step starts in turn (Vitest's node, a
        `git` call from inside a test), because a nested BEAM never reaps its
        port helper and so never passes those children's time up.
      * `cgroup_s` with `cgroup`: the run's cgroup. Under the workspace
        `mix.sh` on a systemd machine that is the run's own scope (`"run"`),
        and the figure is exact and complete. In a container it is the whole
        container, every agent and dev server included (`"shared"`); the
        difference from `gate_s` is then the load beside the run.
      * `host_busy_s`: busy CPU on the whole host (`/proc/stat`), which in a
        container is the host's, not the container's.
  """

  alias Mix.Project
  alias Tymeslot.Precommit.Runner

  @rotate_bytes 5_000_000
  # USER_HZ, the unit of the times in /proc/<pid>/stat and /proc/stat: 100 on
  # every architecture Linux ships for.
  @ticks_per_second 100

  @type t :: %{
          path: Path.t(),
          agent: pid(),
          argv: [String.t()],
          started: integer(),
          started_at: DateTime.t(),
          cpu: map()
        }

  @doc """
  Starts timing a run, or returns nil when recording is off.

  `:path` overrides the file, for tests.
  """
  @spec start([String.t()], keyword()) :: t() | nil
  def start(argv, opts \\ []) do
    case Keyword.get_lazy(opts, :path, &path/0) do
      nil ->
        nil

      path ->
        {:ok, agent} = Agent.start_link(fn -> %{steps: [], plan: nil} end)

        %{
          path: path,
          agent: agent,
          argv: argv,
          started: now(),
          started_at: DateTime.utc_now(),
          cpu: cpu_snapshot()
        }
    end
  end

  @doc """
  The file this machine records to, or nil when `PRECOMMIT_TIMINGS_FILE` is set
  empty.
  """
  @spec path() :: Path.t() | nil
  def path do
    resolve_path(System.get_env("PRECOMMIT_TIMINGS_FILE"), System.get_env("XDG_STATE_HOME"))
  end

  @doc false
  @spec resolve_path(String.t() | nil, String.t() | nil) :: Path.t() | nil
  def resolve_path("", _state_home), do: nil

  def resolve_path(nil, state_home) when state_home in [nil, ""],
    do: resolve_path(nil, Path.join(System.user_home!(), ".local/state"))

  def resolve_path(nil, state_home),
    do: Path.join([state_home, "tymeslot", "precommit_timings.jsonl"])

  def resolve_path(path, _state_home), do: path

  @doc """
  Wraps `Tymeslot.Precommit.Runner.run/3`'s options so every step is timed and
  the run's line is written when its results are in. With recording off, the
  options come back unchanged.
  """
  @spec instrument(t() | nil, [Runner.step()], keyword()) :: keyword()
  def instrument(nil, _steps, opts), do: opts

  def instrument(timings, steps, opts) do
    names = Map.new(steps, fn {name, args, _env} -> {args, name} end)
    cmd = Keyword.get(opts, :cmd, &Runner.cmd/2)
    capture = Keyword.get(opts, :capture, &Runner.capture/3)
    suite_plan = Keyword.get(opts, :suite_plan, fn -> nil end)
    on_results = Keyword.get(opts, :on_results, fn _results -> :ok end)

    Keyword.merge(opts,
      cmd: fn args, env -> time(timings, names, args, [], fn -> cmd.(args, env) end) end,
      capture: fn args, env, extra_env ->
        time(timings, names, args, extra_env, fn -> capture.(args, env, extra_env) end)
      end,
      suite_plan: fn ->
        plan = suite_plan.()
        Agent.update(timings.agent, &%{&1 | plan: plan})
        plan
      end,
      on_results: fn results ->
        on_results.(results)
        finish(timings, results)
      end
    )
  end

  defp time(timings, names, args, extra_env, fun) do
    started = now()
    result = fun.()

    entry =
      put_partition(
        %{
          step: step_name(names, args),
          started_s: seconds(started - timings.started),
          wall_s: seconds(now() - started),
          code: exit_code(result)
        },
        List.keyfind(extra_env, "MIX_TEST_PARTITION", 0)
      )

    Agent.update(timings.agent, &Map.update!(&1, :steps, fn steps -> [entry | steps] end))
    result
  end

  defp exit_code({_output, code}), do: code
  defp exit_code(code), do: code

  defp put_partition(entry, {_key, partition}), do: Map.put(entry, :partition, partition)
  defp put_partition(entry, nil), do: entry

  # A partition runs its step's command with `--partitions <n>` appended.
  defp step_name(names, args) do
    base =
      case Enum.split(args, -2) do
        {base, ["--partitions", _count]} -> base
        _other -> args
      end

    Map.get(names, args) || Map.get(names, base) || Enum.join(args, " ")
  end

  defp finish(timings, results) do
    %{steps: steps, plan: plan} = Agent.get(timings.agent, & &1)
    Agent.stop(timings.agent)

    line = %{
      at: DateTime.to_iso8601(timings.started_at),
      host: hostname(),
      repo: to_string(Project.config()[:app]),
      checkout: File.cwd!(),
      branch: branch(),
      argv: timings.argv,
      parallel: System.get_env("MIX_SH_PARALLEL"),
      result:
        if(Enum.any?(results, &match?({_name, :failed, _code}, &1)), do: "failed", else: "passed"),
      wall_s: seconds(now() - timings.started),
      cpu: cpu_delta(timings.cpu, cpu_snapshot()),
      machine: %{
        logical_cpus: :erlang.system_info(:logical_processors),
        schedulers: System.schedulers_online(),
        cpu_max: read_trimmed(cgroup_file("cpu.max")),
        erl_flags: System.get_env("ERL_FLAGS")
      },
      plan: plan,
      steps: Enum.reverse(steps)
    }

    append(timings.path, JSON.encode!(line) <> "\n")
  rescue
    error ->
      Mix.shell().info([
        :faint,
        "precommit: timings not recorded (#{Exception.message(error)})",
        :reset
      ])
  end

  defp append(path, line) do
    File.mkdir_p!(Path.dirname(path))

    case File.stat(path) do
      {:ok, %{size: size}} when size > @rotate_bytes -> File.rename(path, path <> ".1")
      _small_or_missing -> :ok
    end

    File.write!(path, line, [:append])
  end

  ## CPU

  defp cpu_snapshot do
    %{gate: gate_ticks(), cgroup: cgroup_usage_usec(), host: host_busy_ticks()}
  end

  defp cpu_delta(before, later) do
    %{
      gate_s: diff(before.gate, later.gate, @ticks_per_second),
      cgroup_s: diff(before.cgroup, later.cgroup, 1_000_000),
      cgroup: cgroup_kind(),
      host_busy_s: diff(before.host, later.host, @ticks_per_second)
    }
  end

  defp diff(nil, _later, _unit), do: nil
  defp diff(_before, nil, _unit), do: nil
  defp diff(before, later, unit), do: Float.round((later - before) / unit, 1)

  # This VM's own time, plus each child's own time and the time of the
  # children it has reaped. The VM's one long-lived child is its port helper,
  # erl_child_setup, which starts and reaps every step's process, so its
  # reaped time is the steps'.
  defp gate_ticks do
    own = System.pid()

    case proc_stat("self") do
      {:ok, self_stat} ->
        children =
          "/proc"
          |> File.ls!()
          |> Enum.filter(&String.match?(&1, ~r/^\d+$/))
          |> Enum.map(&proc_stat/1)
          |> Enum.flat_map(fn
            {:ok, %{ppid: ^own} = stat} -> [stat]
            _other -> []
          end)

        Enum.reduce([self_stat | children], 0, &(&2 + &1.ticks))

      :error ->
        nil
    end
  rescue
    _error -> nil
  end

  # The fields after the command name, which is parenthesised and may itself
  # contain spaces and parentheses, hence the split at the last ")": ppid is
  # then the 2nd field, and utime, stime, cutime and cstime the 12th to 15th.
  defp proc_stat(pid) do
    with {:ok, content} <- File.read("/proc/#{pid}/stat"),
         [_first | _rest] = matches <- :binary.matches(content, ")") do
      {position, 1} = List.last(matches)

      fields =
        content |> binary_part(position + 1, byte_size(content) - position - 1) |> String.split()

      ticks = fields |> Enum.slice(11, 4) |> Enum.map(&String.to_integer/1) |> Enum.sum()
      {:ok, %{ppid: Enum.at(fields, 1), ticks: ticks}}
    else
      _unreadable -> :error
    end
  end

  defp host_busy_ticks do
    with {:ok, content} <- File.read("/proc/stat"),
         ["cpu" | values] <- content |> String.split("\n", parts: 2) |> hd() |> String.split() do
      [user, nice, system, _idle, _iowait | rest] = Enum.map(values, &String.to_integer/1)
      # irq, softirq and steal; guest time is already counted in user.
      user + nice + system + (rest |> Enum.take(3) |> Enum.sum())
    else
      _unavailable -> nil
    end
  rescue
    _error -> nil
  end

  defp cgroup_usage_usec do
    with content when is_binary(content) <- read_trimmed(cgroup_file("cpu.stat")),
         [_match, usec] <- Regex.run(~r/^usage_usec (\d+)$/m, content) do
      String.to_integer(usec)
    else
      _unavailable -> nil
    end
  end

  defp cgroup_kind do
    case cgroup_path() do
      nil -> nil
      path -> if String.contains?(path, "mix.slice"), do: "run", else: "shared"
    end
  end

  defp cgroup_file(name) do
    case cgroup_path() do
      nil -> nil
      path -> Path.join(["/sys/fs/cgroup", path, name])
    end
  end

  # cgroup v2 lists a single hierarchy, as `0::<path>`.
  defp cgroup_path do
    with {:ok, content} <- File.read("/proc/self/cgroup"),
         [_match, path] <- Regex.run(~r/^0::(.*)$/m, content) do
      path
    else
      _unavailable -> nil
    end
  end

  ## Context

  defp read_trimmed(nil), do: nil

  defp read_trimmed(path) do
    case File.read(path) do
      {:ok, content} -> String.trim(content)
      {:error, _reason} -> nil
    end
  end

  defp hostname do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end

  defp branch do
    case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], env: [], stderr_to_stdout: true) do
      {name, 0} -> String.trim(name)
      _failed -> nil
    end
  rescue
    _error -> nil
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp seconds(milliseconds), do: Float.round(milliseconds / 1000, 1)
end
