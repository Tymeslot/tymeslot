defmodule Tymeslot.Precommit.Guard do
  @moduledoc """
  Re-runs `mix precommit` through the workspace `mix.sh` when it was started
  outside the resource limits that wrapper applies.

  ## Why the gate re-execs itself

  The limits live in `mix.sh`: a systemd scope per run, capped memory, a
  reduced CPU weight, and a shared `mix.slice` carrying one CPU ceiling for
  every mix run in the workspace at once. None of it reaches a plain
  `mix precommit` typed in a checkout, which is how the gate is usually
  started: from a repo directory, by hand or by an agent, with no wrapper in
  sight. Three such runs across three worktrees saturate all sixteen cores
  between them and hold the package at 89-91C against a 100C critical, because
  nothing they went through knew the other two existed.

  Documenting the wrapper does not fix that, since the unwrapped spelling is
  the shorter one and stays correct-looking. So the gate checks where it is and
  puts itself inside the limits if it is not already there. The wrapper stays
  the single place the limits are defined; this only makes sure runs arrive in
  it.

  ## How a wrapped run is recognised

  `mix.sh` exports `MIX_PRECOMMIT_GUARDED` for the run it starts, including on
  the path where it cannot build a scope at all (no systemd-run, or
  `MIX_NO_MEMORY_CAP=1`), which is what keeps the two from re-execing into each
  other forever. Membership of the slice is checked as well, so a run that
  inherited the variable from an exported shell environment without inheriting
  the cgroup is still wrapped.

  Nothing happens, and the gate simply runs, when there is no wrapper to reach:
  no `mix.sh` above the checkout, or no systemd (CI containers, and every
  non-Linux machine). The gate's own footprint is sized from
  `System.schedulers_online/0` either way, so an unwrapped run is
  unconstrained, not misconfigured.
  """

  @guarded_env "MIX_PRECOMMIT_GUARDED"
  @slice "mix.slice"

  @doc """
  Re-execs the current task through `mix.sh` and halts with its exit status, or
  returns `:ok` to carry on in this process.

  `repo_flag` is the `mix.sh` selector for the calling project, so the re-exec
  runs this repo's gate rather than both.
  """
  @spec ensure_wrapped(String.t(), keyword()) :: :ok
  def ensure_wrapped(repo_flag, opts \\ []) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    argv = Keyword.get(opts, :argv, [])
    env = Keyword.get(opts, :env, &System.get_env/1)
    cgroup = Keyword.get(opts, :cgroup, &read_cgroup/0)

    with false <- wrapped?(env, cgroup),
         {:ok, wrapper} <- find_wrapper(cwd) do
      exec(wrapper, repo_flag, argv, opts)
    else
      _already_wrapped_or_no_wrapper -> :ok
    end
  end

  @doc false
  @spec wrapped?((String.t() -> String.t() | nil), (-> String.t())) :: boolean()
  def wrapped?(env, cgroup), do: env.(@guarded_env) not in [nil, ""] or in_slice?(cgroup.())

  @doc false
  @spec in_slice?(String.t()) :: boolean()
  def in_slice?(cgroup), do: String.contains?(cgroup, @slice)

  @doc """
  The nearest ancestor of `dir` holding a `mix.sh` and the checkouts it drives.

  Mirrors `find_pair_root` in the wrapper: the workspace is resolved from where
  the run started, so a gate started inside a worktree finds that worktree's
  wrapper and not the main checkout's.

  A workspace is recognised by shape rather than by the names of the checkouts
  in it: a `mix.sh` beside two or more directories that are themselves Mix
  projects. Nothing here needs to know what those projects are called, and a
  checkout that sits on its own has no wrapper to find.
  """
  @spec find_wrapper(String.t()) :: {:ok, String.t()} | :error
  def find_wrapper(dir) do
    cond do
      dir in ["/", "."] ->
        :error

      pair_root?(dir) ->
        {:ok, Path.join(dir, "mix.sh")}

      true ->
        parent = Path.dirname(dir)
        if parent == dir, do: :error, else: find_wrapper(parent)
    end
  end

  @projects_in_a_workspace 2

  defp pair_root?(dir) do
    File.regular?(Path.join(dir, "mix.sh")) and
      mix_projects(dir) >= @projects_in_a_workspace
  end

  defp mix_projects(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.count(entries, &File.regular?(Path.join([dir, &1, "mix.exs"])))

      {:error, _reason} ->
        0
    end
  end

  # systemd is the whole mechanism, so a machine without it gets the plain run
  # rather than a wrapper that would only shell back to the same place.
  defp exec(wrapper, repo_flag, argv, opts) do
    cmd = Keyword.get(opts, :cmd, &System.cmd/3)
    halt = Keyword.get(opts, :halt, &System.halt/1)
    shell = Keyword.get(opts, :shell, Mix.shell())

    if Keyword.get(opts, :systemd?, systemd?()) do
      shell.info([
        :faint,
        "==> re-running under #{Path.relative_to_cwd(wrapper)} for the workspace CPU and memory limits",
        :reset
      ])

      {_output, status} =
        cmd.(wrapper, [repo_flag, "precommit" | argv], into: IO.stream(:stdio, :line))

      halt.(status)
    else
      :ok
    end
  end

  defp systemd?,
    do: File.dir?("/sys/fs/cgroup/user.slice") and System.find_executable("systemd-run") != nil

  defp read_cgroup do
    case File.read("/proc/self/cgroup") do
      {:ok, contents} -> contents
      {:error, _reason} -> ""
    end
  end
end
