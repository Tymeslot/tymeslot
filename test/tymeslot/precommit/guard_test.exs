defmodule Tymeslot.Precommit.GuardTest do
  use ExUnit.Case, async: true

  @moduletag :dev_support

  alias Tymeslot.Precommit.Guard

  describe "wrapped?/2" do
    test "the wrapper's marker variable means the run is already inside the limits" do
      assert Guard.wrapped?(fn _var -> "1" end, fn -> "0::/user.slice" end)
    end

    test "membership of the slice counts even without the marker" do
      assert Guard.wrapped?(fn _var -> nil end, fn ->
               "0::/user.slice/user-1000.slice/user@1000.service/mix.slice/run-r1.scope"
             end)
    end

    test "an empty marker is not a marker" do
      refute Guard.wrapped?(fn _var -> "" end, fn -> "0::/user.slice" end)
    end

    test "a bare run in neither is unwrapped" do
      refute Guard.wrapped?(fn _var -> nil end, fn -> "0::/user.slice/user-1000.slice" end)
    end
  end

  describe "find_wrapper/1" do
    setup do
      root = Path.join(System.tmp_dir!(), "guard_test_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(root) end)

      {:ok, root: root}
    end

    test "finds the wrapper beside both checkouts", %{root: root} do
      pair = Path.join(root, "workspace")
      make_pair(pair)

      assert Guard.find_wrapper(pair) == {:ok, Path.join(pair, "mix.sh")}
    end

    test "walks up from inside a checkout", %{root: root} do
      pair = Path.join(root, "workspace")
      make_pair(pair)
      deep = Path.join([pair, "second", "lib", "mix", "tasks"])
      File.mkdir_p!(deep)

      assert Guard.find_wrapper(deep) == {:ok, Path.join(pair, "mix.sh")}
    end

    # The pair is resolved from where the run started, so a worktree's gate is
    # wrapped by that worktree's mix.sh and not by the main checkout's.
    test "prefers the nearest pair when a worktree nests inside one", %{root: root} do
      outer = Path.join(root, "workspace")
      inner = Path.join([outer, ".worktrees", "branch"])
      make_pair(outer)
      make_pair(inner)

      assert Guard.find_wrapper(Path.join(inner, "first")) ==
               {:ok, Path.join(inner, "mix.sh")}
    end

    test "a checkout with no wrapper above it has nothing to re-exec into", %{root: root} do
      lonely = Path.join(root, "solo")
      File.mkdir_p!(lonely)

      assert Guard.find_wrapper(lonely) == :error
    end

    # A workspace is a wrapper beside the checkouts it drives. A single Mix
    # project that happens to carry a mix.sh of its own is not one, and a gate
    # run there would otherwise shell into a script that knows nothing about it.
    test "one checkout beside a mix.sh is not a workspace", %{root: root} do
      half = Path.join(root, "half")
      File.mkdir_p!(Path.join(half, "first"))
      File.write!(Path.join([half, "first", "mix.exs"]), "")
      File.write!(Path.join(half, "mix.sh"), "")

      assert Guard.find_wrapper(half) == :error
    end

    test "the checkouts are recognised by shape, whatever they are called",
         %{root: root} do
      pair = Path.join(root, "oddly-named")
      File.mkdir_p!(Path.join(pair, "alpha"))
      File.mkdir_p!(Path.join(pair, "beta"))
      File.write!(Path.join([pair, "alpha", "mix.exs"]), "")
      File.write!(Path.join([pair, "beta", "mix.exs"]), "")
      File.write!(Path.join(pair, "mix.sh"), "")

      assert Guard.find_wrapper(pair) == {:ok, Path.join(pair, "mix.sh")}
    end
  end

  describe "ensure_wrapped/2" do
    test "an already-wrapped run carries on in this process" do
      assert Guard.ensure_wrapped("--core",
               env: fn _var -> "1" end,
               cgroup: fn -> "" end,
               cmd: fn _wrapper, _args, _opts -> flunk("re-exec attempted") end
             ) == :ok
    end

    test "a run with no wrapper above it carries on in this process" do
      assert Guard.ensure_wrapped("--core",
               cwd: System.tmp_dir!(),
               env: fn _var -> nil end,
               cgroup: fn -> "" end,
               cmd: fn _wrapper, _args, _opts -> flunk("re-exec attempted") end
             ) == :ok
    end

    test "a machine without systemd has no limits to re-exec into" do
      pair = Path.join(System.tmp_dir!(), "guard_nosystemd_#{System.unique_integer([:positive])}")
      make_pair(pair)
      on_exit(fn -> File.rm_rf!(pair) end)

      assert Guard.ensure_wrapped("--core",
               cwd: pair,
               env: fn _var -> nil end,
               cgroup: fn -> "" end,
               systemd?: false,
               cmd: fn _wrapper, _args, _opts -> flunk("re-exec attempted") end
             ) == :ok
    end

    test "an unwrapped run re-execs the selected repo's gate and halts with its status" do
      pair = Path.join(System.tmp_dir!(), "guard_exec_#{System.unique_integer([:positive])}")
      make_pair(pair)
      on_exit(fn -> File.rm_rf!(pair) end)

      test_pid = self()

      Guard.ensure_wrapped("--core",
        cwd: pair,
        argv: ["--fail-fast"],
        env: fn _var -> nil end,
        cgroup: fn -> "" end,
        systemd?: true,
        shell: Mix.Shell.Quiet,
        cmd: fn wrapper, args, _opts ->
          send(test_pid, {:ran, wrapper, args})
          {"", 3}
        end,
        halt: fn status -> send(test_pid, {:halted, status}) end
      )

      assert_received {:ran, wrapper, ["--core", "precommit", "--fail-fast"]}
      assert wrapper == Path.join(pair, "mix.sh")
      assert_received {:halted, 3}
    end
  end

  defp make_pair(dir) do
    File.mkdir_p!(Path.join(dir, "first"))
    File.mkdir_p!(Path.join(dir, "second"))
    File.write!(Path.join([dir, "first", "mix.exs"]), "")
    File.write!(Path.join([dir, "second", "mix.exs"]), "")
    File.write!(Path.join(dir, "mix.sh"), "")
  end
end
