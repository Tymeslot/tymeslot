defmodule Tymeslot.Precommit.PassRecord do
  @moduledoc """
  Remembers which gate steps passed on which tree, so `mix precommit
  --affected` does not run a step again on content it already passed.

  The same commits are gated before the commit, before the push (`--base
  @{u}`) and before the merge (`--base main`). When nothing changed in
  between, the second and third runs repeat the first. Each run records its
  passing steps under a key for the content it ran against, and a later
  `--affected` run over the same content lists those steps as `not run`
  instead of running them.

  ## The key

  The content of the working tree, not `HEAD`: uncommitted and untracked
  files count, ignored ones do not. It is the tree object `git write-tree`
  would produce if everything were staged, built from a copy of the index so
  the real one is never touched. A repository that builds against a path
  dependency (SaaS against Core) adds the dependency's tree, and the Elixir and
  OTP versions are part of it too.

  A step counts as passed when the same command passed under the same key.
  A suite step run on selected files also counts as passed when the whole
  suite passed, which covers every selection.

  The full gate records what passes but never skips on the record: asking for
  it means asking for everything to run. `hex.audit` is never recorded, since
  its answer comes from the live Hex registry, not the tree. A run whose tree
  moved while it ran records nothing, since its passes may describe neither
  tree.

  The record lives in `_build/precommit_passes`, per checkout, and keeps the
  last 500 entries.
  """

  alias Mix.Project
  alias Tymeslot.Precommit.Runner

  @type t :: %{path: Path.t(), key: String.t() | nil, dirs: [Path.t()], passed: MapSet.t()}

  @limit 500
  @never_recorded ~w[hex.audit]

  @doc """
  Opens the record for the repository in the current directory. A tree that
  cannot be hashed (no git, say) yields a record that skips and saves nothing.

  ## Options

    * `:upstream_dir` - the checkout of the path dependency this repository
      builds against, whose tree is part of the key.
    * `:dir` - the repository, by default the current directory.
    * `:path` - the record file, by default `_build/precommit_passes`.
  """
  @spec open(keyword()) :: t()
  def open(opts \\ []) do
    dirs = Enum.reject([Keyword.get(opts, :dir, "."), opts[:upstream_dir]], &is_nil/1)
    path = Keyword.get_lazy(opts, :path, &default_path/0)
    key = key(dirs)

    %{path: path, key: key, dirs: dirs, passed: if(key, do: read(path, key), else: MapSet.new())}
  end

  defp default_path, do: Path.join(Path.dirname(Project.build_path()), "precommit_passes")

  @doc """
  Splits `steps` into those still to run and those already passed on this
  tree, the latter as `{name, reason}` pairs for the summary.
  """
  @spec split(t(), [Runner.step()]) :: {[Runner.step()], [{String.t(), String.t()}]}
  def split(record, steps) do
    {passed, to_run} = Enum.split_with(steps, &passed?(record, &1))

    {to_run,
     Enum.map(passed, fn {name, _args, _env} -> {name, "passed on this tree already"} end)}
  end

  @doc """
  Records the steps among `steps` that `results` reports as passed, unless the
  tree moved since `open/1`.
  """
  @spec save(t(), [Runner.step()], [Runner.result()]) :: :ok
  def save(%{key: nil}, _steps, _results), do: :ok

  def save(record, steps, results) do
    passed = for {name, :passed, _code} <- results, into: MapSet.new(), do: name

    lines =
      for {name, [command | _rest], _env} = step <- steps,
          name in passed,
          command not in @never_recorded,
          do: "#{record.key} #{step_id(step)}\n"

    if lines != [] and key(record.dirs) == record.key do
      File.mkdir_p!(Path.dirname(record.path))
      kept = record.path |> existing_lines() |> Enum.take(-(@limit - length(lines)))
      File.write!(record.path, [Enum.map(kept, &[&1, "\n"]), lines])
    end

    :ok
  end

  @doc false
  @spec passed?(t(), Runner.step()) :: boolean()
  def passed?(%{key: nil}, _step), do: false

  def passed?(record, {name, [command | args], env} = step) do
    MapSet.member?(record.passed, step_id(step)) or
      (Runner.suite?(step) and args != [] and "--include" not in args and
         MapSet.member?(record.passed, step_id({name, [command], env})))
  end

  defp step_id(step),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(step)) |> Base.encode16() |> binary_part(0, 16)

  defp read(path, key) do
    prefix = key <> " "

    for line <- existing_lines(path),
        String.starts_with?(line, prefix),
        into: MapSet.new(),
        do: String.replace_prefix(line, prefix, "")
  end

  defp existing_lines(path) do
    case File.read(path) do
      {:ok, content} -> String.split(content, "\n", trim: true)
      {:error, _reason} -> []
    end
  end

  defp key(dirs) do
    trees = Enum.map(dirs, &tree/1)

    if Enum.all?(trees, & &1) do
      [System.version(), System.otp_release() | trees] |> Enum.join(":") |> hash()
    end
  end

  defp hash(text), do: :crypto.hash(:sha256, text) |> Base.encode16() |> binary_part(0, 24)

  # The tree `git write-tree` would give with every change staged, built in a
  # copy of the index so the real one and the staging area are left alone.
  defp tree(dir) do
    tmp = Path.join(System.tmp_dir!(), "precommit-index-#{System.unique_integer([:positive])}")

    try do
      with {index, 0} <- git(dir, ["rev-parse", "--git-path", "index"], nil),
           :ok <- copy_index(Path.expand(String.trim(index), dir), tmp),
           {_out, 0} <- git(dir, ["add", "--all"], tmp),
           {tree, 0} <- git(dir, ["write-tree"], tmp) do
        String.trim(tree)
      else
        _failure -> nil
      end
    after
      File.rm(tmp)
    end
  end

  defp copy_index(index, tmp) do
    if File.exists?(index), do: File.cp(index, tmp), else: :ok
  end

  defp git(dir, args, index_file) do
    env = if index_file, do: [{"GIT_INDEX_FILE", index_file}], else: []
    System.cmd("git", args, cd: dir, env: env, stderr_to_stdout: true)
  rescue
    ErlangError -> {"", 1}
  end
end
