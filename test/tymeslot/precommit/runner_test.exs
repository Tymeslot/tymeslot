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

  # Dialyzer sizes its worker pool to the number of online schedulers, so
  # uncapped it scales its memory with the host's core count rather than with
  # the project. Left alone on a 16-core machine that has been enough to push
  # the desktop into an OOM kill, so the cap failing silently is the failure
  # mode worth a test: nothing else in a `mix precommit` run would report it.
  describe "step_env/1" do
    test "caps schedulers for the dialyzer step" do
      assert Runner.step_env(["dialyzer"]) == [{"ERL_FLAGS", "+S 4:4"}]
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
