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
    test "the suite runs while the later foreground steps do" do
      test_pid = self()

      steps = [
        {"compile", ["compile"], :dev},
        {"test", ["test"], :test},
        {"credo", ["credo"], :dev}
      ]

      # The suite blocks until the foreground releases it, so the run can only
      # finish if the two were genuinely in flight at the same time. Verified by
      # reverting the runner to the sequential path: this and the two cases
      # below go red, here because a sequential run puts the suite through
      # `cmd` instead, which this stub deliberately has no clause for.
      capture_fun = fn ["test"], :test ->
        send(test_pid, {:suite_started, self()})

        receive do
          :release -> {"suite output\n", 0}
        end
      end

      cmd_fun = fn
        ["compile"], :dev ->
          0

        ["credo"], :dev ->
          assert_receive {:suite_started, suite}
          send(suite, :release)
          0
      end

      output =
        capture_plain(fn ->
          assert Runner.run(steps, false, cmd: cmd_fun, capture: capture_fun) == :ok
        end)

      assert output =~ "ok      test"
      assert output =~ "ok      credo"
      assert output =~ "suite output"
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
                   cmd: stub(%{["compile"] => 0, ["dialyzer.incremental"] => 0}),
                   capture: fn ["test"], :test -> {"", 0} end
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
                     capture: fn ["test"], :test -> {"1 test, 1 failure\n", 2} end
                   )
                 ) == {:shutdown, 1}
        end)

      assert output =~ "failed  test (2)"
      assert output =~ "1 test, 1 failure"
    end

    test "a broken build never starts the suite" do
      steps = [{"compile", ["compile"], :dev}, {"test", ["test"], :test}]

      capture_fun = fn _args, _env ->
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
      steps = [{"compile", ["compile"], :dev}, {"test", ["test"], :test}]

      capture_fun = fn _args, _env -> flunk("--fail-fast must not background a step") end

      output =
        capture_plain(fn ->
          assert Runner.run(steps, true,
                   cmd: stub(%{["compile"] => 0, ["test"] => 0}),
                   capture: capture_fun
                 ) == :ok
        end)

      assert output =~ "ok      test"
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
