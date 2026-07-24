defmodule Tymeslot.Precommit.RunnerTest do
  use ExUnit.Case, async: true

  @moduletag :dev_support

  import ExUnit.CaptureIO

  alias Tymeslot.Precommit.Runner

  defp stub(exit_codes) do
    fn args, _env -> Map.fetch!(exit_codes, args) end
  end

  describe "run/3" do
    test "all-pass steps report ok and return :ok" do
      steps = [{"a", ["a"], :dev}, {"b", ["b"], :dev}, {"c", ["c"], :test}]
      cmd_fun = stub(%{["a"] => 0, ["b"] => 0, ["c"] => 0})

      output =
        capture_io(fn ->
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
        capture_io(fn ->
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
        capture_io(fn ->
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
        capture_io(fn ->
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
        capture_io(fn ->
          assert catch_exit(Runner.run(steps, true, cmd: cmd_fun)) == {:shutdown, 1}
        end)

      assert output =~ "failed  a (1)"
      refute output =~ "b"
      refute output =~ "c"
      refute output =~ "skipped"
    end
  end
end
