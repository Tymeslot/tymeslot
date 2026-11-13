defmodule Tymeslot.Precommit.RunnerHelpersTest do
  use ExUnit.Case, async: true

  @moduletag :dev_support

  alias Tymeslot.Precommit.Runner

  describe "suite?/1" do
    test "is keyed off the command, so either repository's suite command counts" do
      assert Runner.suite?({"test", ["test"], :test})
      assert Runner.suite?({"test", ["test.elixir", "test/a_test.exs"], :test})
      refute Runner.suite?({"js", ["test.js"], :dev})
      refute Runner.suite?({"test", ["credo", "--strict"], :dev})
    end
  end

  # Only the suite carries a timeout, so it alone keeps the default priority; a
  # niced suite would hand its partitions the lower priority too.
  describe "launcher/1" do
    test "starts either repository's suite at the default priority" do
      assert Runner.launcher(["test"]) == {"mix", ["test"]}

      assert Runner.launcher(["test.elixir", "--partitions", "4"]) ==
               {"mix", ["test.elixir", "--partitions", "4"]}
    end

    test "starts every other step under nice" do
      nice = System.find_executable("nice")

      for args <- [["dialyzer.incremental"], ["credo", "--strict"], ["test.js"]] do
        assert Runner.launcher(args) == {nice, ["-n", "10", "mix" | args]}
      end
    end

    # The kernel caps niceness at 19, and the workspace `mix.sh` already runs
    # the whole gate at 10, so the expected value is capped too.
    test "the command it builds lowers the priority of what it runs" do
      {nice, ["-n", increment, "mix" | _args]} = Runner.launcher(["credo"])
      {own, 0} = System.cmd(nice, [], env: [])
      {lowered, 0} = System.cmd(nice, ["-n", increment, nice], env: [])
      own = own |> String.trim() |> String.to_integer()

      assert String.to_integer(String.trim(lowered)) ==
               min(own + String.to_integer(increment), 19)
    end
  end

  # The fixture is a warning the compiler printed verbatim while building this
  # repository as a path dependency, so the pattern is pinned to the real
  # location format rather than to a guess at it.
  describe "dependency_warnings/2" do
    @dependency_warning """
    ==> tymeslot
        warning: TymeslotWeb.Test.FixtureTheme.Theme.live_view_module/0 is undefined (module TymeslotWeb.Test.FixtureTheme.Theme is not available or is yet to be defined)
        │
     99 │       module -> module.live_view_module()
        │                        ~
        │
        └─ (tymeslot 1.19.0) lib/tymeslot_web/themes/core/theme_info.ex:99:24: TymeslotWeb.Themes.Core.ThemeInfo.get_live_view_module/1

    ==> app
    Generated app app
    """

    test "names a path dependency a warning is located in" do
      assert Runner.dependency_warnings(@dependency_warning, [:tymeslot]) == [:tymeslot]
    end

    test "names each dependency once, however many warnings it printed" do
      output = @dependency_warning <> @dependency_warning
      assert Runner.dependency_warnings(output, [:tymeslot]) == [:tymeslot]
    end

    test "ignores a warning in a dependency that is not a path dependency" do
      assert Runner.dependency_warnings(@dependency_warning, [:other]) == []
    end

    test "ignores a warning in the project's own files" do
      output = String.replace(@dependency_warning, "(tymeslot 1.19.0) ", "")
      assert Runner.dependency_warnings(output, [:tymeslot]) == []
    end

    test "a clean build names none" do
      assert Runner.dependency_warnings("==> tymeslot\nCompiling 3 files (.ex)\n", [:tymeslot]) ==
               []
    end
  end

  describe "step_env/1" do
    test "caps schedulers for the dialyzer step" do
      assert [{"ERL_FLAGS", flags}] = Runner.step_env(["dialyzer"])
      assert flags == "+S #{expected_dialyzer_schedulers()}:#{expected_dialyzer_schedulers()}"
    end

    # The gate runs the incremental task and keeps `dialyzer` as the cross-check.
    # Both need the cap, and the clause that applies it matches on the task name,
    # so a step reworded to one and not the other would silently lose it.
    test "caps schedulers for the incremental dialyzer step too" do
      assert [{"ERL_FLAGS", flags}] =
               Runner.step_env(["dialyzer.incremental", "--list-unused-filters"])

      assert flags == "+S #{expected_dialyzer_schedulers()}:#{expected_dialyzer_schedulers()}"
    end

    # Eight measured fastest on a 16-core host; a machine with fewer cores must
    # not be handed more schedulers than it has.
    test "caps dialyzer at eight schedulers, or the cores available when fewer" do
      assert Runner.dialyzer_schedulers(16) == 8
      assert Runner.dialyzer_schedulers(64) == 8
      assert Runner.dialyzer_schedulers(4) == 4
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

  defp expected_dialyzer_schedulers, do: min(8, System.schedulers_online())
end
