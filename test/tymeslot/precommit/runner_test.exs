defmodule Tymeslot.Precommit.RunnerTest do
  use ExUnit.Case, async: true

  @moduletag :dev_support

  import ExUnit.CaptureIO

  alias Tymeslot.Precommit.Runner

  @ansi ~r/\e\[[0-9;]*m/

  defp stub(exit_codes) do
    fn args, _env -> Map.fetch!(exit_codes, args) end
  end

  # `Mix.shell().info/1` colours its output whenever it is attached to a
  # terminal, which splits markers such as "ok      " from the step name with a
  # reset sequence. Assert on the plain text so a run in a terminal and a piped
  # run (CI) agree.
  defp capture_plain(fun), do: fun |> capture_io() |> String.replace(@ansi, "")

  describe "run/3" do
    test "all-pass steps report ok and return :ok" do
      steps = [{"a", ["a"], :dev}, {"b", ["b"], :dev}, {"c", ["c"], :test}]
      cmd_fun = stub(%{["a"] => 0, ["b"] => 0, ["c"] => 0})

      output =
        capture_plain(fn ->
          assert Runner.run(steps, false, cmd: cmd_fun) == :ok
        end)

      assert output =~ "ok      a"
      assert output =~ "ok      b"
      assert output =~ "ok      c"
      refute output =~ "skipped"
    end

    test "a mid-list failure keeps going and collects both results" do
      steps = [{"a", ["a"], :dev}, {"b", ["b"], :dev}, {"c", ["c"], :dev}]
      cmd_fun = stub(%{["a"] => 0, ["b"] => 1, ["c"] => 0})

      output =
        capture_plain(fn ->
          assert catch_exit(Runner.run(steps, false, cmd: cmd_fun)) == {:shutdown, 1}
        end)

      assert output =~ "ok      a"
      assert output =~ "failed  b (1)"
      assert output =~ "ok      c"
    end

    test "a barrier (compile) failure yields the skipped marker and drops remaining steps" do
      steps = [{"compile", ["compile"], :dev}, {"credo", ["credo"], :dev}]
      cmd_fun = stub(%{["compile"] => 1, ["credo"] => 0})

      output =
        capture_plain(fn ->
          assert catch_exit(Runner.run(steps, false, cmd: cmd_fun)) == {:shutdown, 1}
        end)

      assert output =~ "failed  compile (1)"
      assert output =~ "skipped remaining steps: the build is broken"
      refute output =~ "credo"
    end

    test "a second compile step (e.g. a different MIX_ENV) is also a barrier" do
      steps = [
        {"compile", ["compile"], :dev},
        {"compile (test)", ["compile"], :test},
        {"credo", ["credo"], :dev}
      ]

      cmd_fun = fn
        ["compile"], :dev -> 0
        ["compile"], :test -> 1
        ["credo"], :dev -> 0
      end

      output =
        capture_plain(fn ->
          assert catch_exit(Runner.run(steps, false, cmd: cmd_fun)) == {:shutdown, 1}
        end)

      assert output =~ "ok      compile"
      assert output =~ "failed  compile (test) (1)"
      assert output =~ "skipped remaining steps: the build is broken"
      refute output =~ "ok      credo"
    end

    test "fail_fast?: true stops at the first failure" do
      steps = [{"a", ["a"], :dev}, {"b", ["b"], :dev}, {"c", ["c"], :dev}]
      cmd_fun = stub(%{["a"] => 1, ["b"] => 0, ["c"] => 0})

      output =
        capture_plain(fn ->
          assert catch_exit(Runner.run(steps, true, cmd: cmd_fun)) == {:shutdown, 1}
        end)

      assert output =~ "failed  a (1)"
      refute output =~ "b"
      refute output =~ "c"
      refute output =~ "skipped"
    end
  end

  describe "run/3 with the suite in the background" do
    test "the suite runs while the static checks do" do
      test_pid = self()

      steps = [
        {"compile", ["compile"], :dev},
        {"test", ["test"], :test},
        {"credo", ["credo"], :dev}
      ]

      # Both block until released, and the test releases them only once both
      # have reported starting, so the run can only finish if the suite and
      # credo were genuinely in flight at the same time.
      capture_fun = fn [name], _env, [] ->
        send(test_pid, {:started, name, self()})

        receive do
          :release -> {"#{name} output\n", 0}
        end
      end

      output =
        capture_plain(fn ->
          runner =
            Task.async(fn ->
              Runner.run(steps, false, cmd: stub(%{["compile"] => 0}), capture: capture_fun)
            end)

          assert_receive {:started, first, first_pid}, 1_000
          assert_receive {:started, second, second_pid}, 1_000
          assert Enum.sort([first, second]) == ["credo", "test"]

          send(first_pid, :release)
          send(second_pid, :release)
          assert Task.await(runner) == :ok
        end)

      assert output =~ "ok      test"
      assert output =~ "ok      credo"
      assert output =~ "test output"
    end

    test "the summary keeps the declared order, not the order results arrived" do
      steps = [
        {"compile", ["compile"], :dev},
        {"test", ["test"], :test},
        {"dialyzer", ["dialyzer.incremental"], :dev}
      ]

      output =
        capture_plain(fn ->
          assert Runner.run(steps, false,
                   cmd: stub(%{["compile"] => 0}),
                   capture: fn args, _env, [] ->
                     {"", Map.fetch!(%{["test"] => 0, ["dialyzer.incremental"] => 0}, args)}
                   end
                 ) == :ok
        end)

      summary = output |> String.split("Summary") |> List.last()

      assert [_compile, "test", "dialyzer"] =
               Enum.map(Regex.scan(~r/ok\s+(\S+)/, summary), &List.last/1)
    end

    test "a failing suite is reported and fails the run" do
      steps = [{"compile", ["compile"], :dev}, {"test", ["test"], :test}]

      output =
        capture_plain(fn ->
          assert catch_exit(
                   Runner.run(steps, false,
                     cmd: stub(%{["compile"] => 0}),
                     capture: fn ["test"], :test, [] -> {"1 test, 1 failure\n", 2} end
                   )
                 ) == {:shutdown, 1}
        end)

      assert output =~ "failed  test (2)"
      assert output =~ "1 test, 1 failure"
    end

    test "a broken build never starts the suite" do
      steps = [{"compile", ["compile"], :dev}, {"test", ["test"], :test}]

      capture_fun = fn _args, _env, _extra_env ->
        flunk("the suite ran against a build that does not compile")
      end

      output =
        capture_plain(fn ->
          assert catch_exit(
                   Runner.run(steps, false, cmd: stub(%{["compile"] => 1}), capture: capture_fun)
                 ) == {:shutdown, 1}
        end)

      assert output =~ "failed  compile (1)"
      assert output =~ "skipped remaining steps: the build is broken"
    end

    test "--fail-fast runs everything in sequence" do
      steps = [
        {"compile", ["compile"], :dev},
        {"credo", ["credo"], :dev},
        {"test", ["test"], :test}
      ]

      capture_fun = fn _args, _env, _extra_env ->
        flunk("--fail-fast must not run a step concurrently")
      end

      output =
        capture_plain(fn ->
          assert Runner.run(steps, true,
                   cmd: stub(%{["compile"] => 0, ["credo"] => 0, ["test"] => 0}),
                   capture: capture_fun
                 ) == :ok
        end)

      assert output =~ "ok      credo"
      assert output =~ "ok      test"
    end
  end

  describe "run/3 with the static checks running concurrently" do
    test "the static checks after the compile barriers overlap each other" do
      test_pid = self()

      steps = [
        {"compile", ["compile"], :dev},
        {"credo", ["credo"], :dev},
        {"sobelow", ["sobelow"], :dev}
      ]

      # Each check reports that it started and then blocks until released. The
      # test releases them only once both have reported, so a runner that ran
      # them one after the other never gets the second report.
      capture_fun = fn [name], :dev, [] ->
        send(test_pid, {:started, name, self()})

        receive do
          :release -> {"#{name} output\n", 0}
        end
      end

      output =
        capture_plain(fn ->
          runner =
            Task.async(fn ->
              Runner.run(steps, false, cmd: stub(%{["compile"] => 0}), capture: capture_fun)
            end)

          assert_receive {:started, first, first_pid}, 1_000
          assert_receive {:started, second, second_pid}, 1_000
          assert Enum.sort([first, second]) == ["credo", "sobelow"]

          send(first_pid, :release)
          send(second_pid, :release)
          assert Task.await(runner) == :ok
        end)

      assert output =~ "credo output"
      assert output =~ "sobelow output"
      assert output =~ "ok      credo"
      assert output =~ "ok      sobelow"
    end

    test "a step that writes the build finishes before the concurrent checks start" do
      test_pid = self()

      steps = [
        {"compile", ["compile"], :dev},
        {"gettext", ["gettext.check"], :dev},
        {"credo", ["credo"], :dev}
      ]

      # gettext runs in the calling process, so a credo already in flight would
      # have reported by the time the refutation's window closes.
      cmd_fun = fn
        ["compile"], :dev ->
          0

        ["gettext.check"], :dev ->
          refute_receive :credo_started, 200
          0
      end

      capture_fun = fn ["credo"], :dev, [] ->
        send(test_pid, :credo_started)
        {"", 0}
      end

      output =
        capture_plain(fn ->
          assert Runner.run(steps, false, cmd: cmd_fun, capture: capture_fun) == :ok
        end)

      assert_received :credo_started
      assert output =~ "ok      gettext"
    end

    test "a failing concurrent check is reported with its output and fails the run" do
      steps = [
        {"compile", ["compile"], :dev},
        {"credo", ["credo"], :dev},
        {"sobelow", ["sobelow"], :dev}
      ]

      capture_fun = fn
        ["credo"], :dev, [] -> {"2 issues found\n", 4}
        ["sobelow"], :dev, [] -> {"", 0}
      end

      output =
        capture_plain(fn ->
          assert catch_exit(
                   Runner.run(steps, false, cmd: stub(%{["compile"] => 0}), capture: capture_fun)
                 ) == {:shutdown, 1}
        end)

      assert output =~ "2 issues found"
      assert output =~ "failed  credo (4)"
      assert output =~ "ok      sobelow"
    end
  end

  describe "run/3 with a partitioned suite" do
    setup do
      steps = [{"compile", ["compile"], :dev}, {"test", ["test"], :test}]
      %{steps: steps, cmd: stub(%{["compile"] => 0})}
    end

    test "runs one mix test per partition, each numbered and capped, all at once",
         %{steps: steps, cmd: cmd} do
      test_pid = self()

      # Each partition reports and blocks until released, and the test releases
      # them only once all three have reported, so they must overlap.
      capture_fun = fn ["test", "--partitions", "3"], :test, extra_env ->
        env = Map.new(extra_env)
        send(test_pid, {:partition, env["MIX_TEST_PARTITION"], env, self()})

        receive do
          :release -> {"partition #{env["MIX_TEST_PARTITION"]} ran\n", 0}
        end
      end

      output =
        capture_plain(fn ->
          runner =
            Task.async(fn ->
              Runner.run(steps, false,
                cmd: cmd,
                capture: capture_fun,
                suite_plan: fn -> %{partitions: 3, schedulers: 4} end
              )
            end)

          partitions =
            for _partition <- 1..3 do
              assert_receive {:partition, number, env, pid}, 1_000
              send(pid, :release)
              {number, env}
            end

          assert partitions |> Enum.map(&elem(&1, 0)) |> Enum.sort() == ["1", "2", "3"]

          for {_number, env} <- partitions do
            assert env["ERL_FLAGS"] =~ ~r/\+S 4:4$/
          end

          assert Task.await(runner) == :ok
        end)

      assert output =~ "3 partitions of 4 schedulers each"
      assert output =~ "--- partition 1 of 3 ---\npartition 1 ran"
      assert output =~ "--- partition 3 of 3 ---\npartition 3 ran"
      assert output =~ "ok      test"
    end

    test "one failing partition fails the suite", %{steps: steps, cmd: cmd} do
      capture_fun = fn _args, :test, extra_env ->
        case List.keyfind(extra_env, "MIX_TEST_PARTITION", 0) do
          {_key, "2"} -> {"1 failure\n", 2}
          _other -> {"", 0}
        end
      end

      output =
        capture_plain(fn ->
          assert catch_exit(
                   Runner.run(steps, false,
                     cmd: cmd,
                     capture: capture_fun,
                     suite_plan: fn -> %{partitions: 3, schedulers: 2} end
                   )
                 ) == {:shutdown, 1}
        end)

      assert output =~ "--- partition 2 of 3 ---\n1 failure"
      assert output =~ "failed  test (2)"
    end

    test "no plan runs the suite whole", %{steps: steps, cmd: cmd} do
      output =
        capture_plain(fn ->
          assert Runner.run(steps, false,
                   cmd: cmd,
                   capture: fn ["test"], :test, [] -> {"whole\n", 0} end,
                   suite_plan: fn -> nil end
                 ) == :ok
        end)

      assert output =~ "whole"
      refute output =~ "partition"
    end
  end

  # The scheduler count is a measured speed setting (see `step_env/1` for the
  # numbers), and losing it is the kind of regression nothing else in a `mix
  # precommit` run would report: the gate would simply get slower, silently and
  # by about a fifth. Hence a test on the flag itself.
  describe "step_env/1" do
    test "caps schedulers for the dialyzer step" do
      assert Runner.step_env(["dialyzer"]) == [{"ERL_FLAGS", "+S 8:8"}]
    end

    # The gate runs the incremental task and keeps `dialyzer` as the cross-check.
    # Both need the cap, and the clause that applies it matches on the task name,
    # so a step reworded to one and not the other would silently lose it.
    test "caps schedulers for the incremental dialyzer step too" do
      assert Runner.step_env(["dialyzer.incremental", "--list-unused-filters"]) ==
               [{"ERL_FLAGS", "+S 8:8"}]
    end

    test "leaves every other step's environment alone" do
      assert Runner.step_env(["test"]) == []
      assert Runner.step_env(["credo", "--strict"]) == []
      assert Runner.step_env(["compile", "--warnings-as-errors"]) == []
    end

    # The `MIX_DIALYZER_SCHEDULERS` override is deliberately not covered here.
    # Asserting on it means mutating the OS environment, which every other case
    # in this async module would race against — the same shared-global problem
    # that pushes modules to `async: false` across this suite. It is a plain
    # `System.get_env/2` default; the branch that matters is tested above.
  end
end
