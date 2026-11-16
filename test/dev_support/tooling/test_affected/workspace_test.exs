defmodule Tymeslot.TestAffected.WorkspaceTest do
  use ExUnit.Case, async: true

  @moduletag :dev_support

  alias Tymeslot.TestAffected.Selection
  alias Tymeslot.TestAffected.Workspace

  describe "index/1" do
    @tag :tmp_dir
    test "a path mentioned only in prose does not count as naming it", %{tmp_dir: dir} do
      write!(dir, "lib/tymeslot/reader.ex", ~S'''
      defmodule Tymeslot.Reader do
        @moduledoc """
        Mentions priv/prose_only/notes in its documentation.
        """

        # And priv/prose_only/notes in a comment.
        def read, do: File.read!("priv/real/data")
      end
      ''')

      write!(dir, "test/tymeslot/reader_test.exs", """
      defmodule Tymeslot.ReaderTest do
        use ExUnit.Case
        @moduletag :auth
      end
      """)

      # Two bystanders keep one file under the share at which Selection gives up.
      for name <- ~w[one two], do: write!(dir, "test/tymeslot/#{name}_test.exs", "")

      index = Workspace.index(dir)

      assert MapSet.size(index.test_files) == 3
      assert index.tags["test/tymeslot/reader_test.exs"] == MapSet.new([:auth])

      assert Selection.plan(["priv/real/data"], index).files == ["test/tymeslot/reader_test.exs"]
      assert Selection.plan(["priv/prose_only/notes"], index).scope == :full_suite
    end
  end

  describe "index/1 naming modules" do
    @tag :tmp_dir
    test "a module brought in by a multi-alias is found by its full name", %{tmp_dir: dir} do
      write!(dir, "lib/tymeslot/widgets/dial.ex", "defmodule Tymeslot.Widgets.Dial do\nend\n")

      write!(dir, "test/tymeslot_web/panel_test.exs", """
      defmodule TymeslotWeb.PanelTest do
        @moduletag :auth
        alias Tymeslot.Widgets.{
          Knob,
          Dial
        }
      end
      """)

      for name <- ~w[one two three], do: write!(dir, "test/tymeslot_web/#{name}_test.exs", "")

      plan = Selection.plan(["lib/tymeslot/widgets/dial.ex"], Workspace.index(dir))

      # With no mirror anywhere, an unnamed module would widen.
      assert plan.scope == :selection
      assert "test/tymeslot_web/panel_test.exs" in plan.files
    end

    @tag :tmp_dir
    test "a support module the suite's configuration names widens", %{tmp_dir: dir} do
      write!(dir, "test/support/clock_mock.ex", "defmodule Tymeslot.ClockMock do\nend\n")
      write!(dir, "config/test.exs", "config :tymeslot, clock: Tymeslot.ClockMock\n")
      write!(dir, "test/tymeslot/clock_test.exs", "Tymeslot.ClockMock.now()\n")

      plan = Selection.plan(["test/support/clock_mock.ex"], Workspace.index(dir))

      assert plan.scope == :full_suite
      assert Enum.any?(plan.reasons, &(&1 =~ "config/test.exs"))
    end
  end

  describe "lint_inputs/1" do
    @tag :tmp_dir
    test "lists what a full format and Credo run would read", %{tmp_dir: dir} do
      write!(dir, ".formatter.exs", ~s|[inputs: ["{lib,test}/**/*.{ex,exs}"]]|)

      write!(dir, ".credo.exs", ~S"""
      %{configs: [%{files: %{included: ["lib/"], excluded: [~r"/lib/generated/"]}}]}
      """)

      for path <- ~w[lib/a.ex lib/generated/b.ex test/a_test.exs priv/repo/seeds.exs],
          do: write!(dir, path, "")

      inputs = Workspace.lint_inputs(dir)

      assert inputs["format"] ==
               MapSet.new(~w[lib/a.ex lib/generated/b.ex test/a_test.exs])

      assert inputs["credo"] == MapSet.new(~w[lib/a.ex])
    end
  end

  defp write!(dir, path, contents) do
    file = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, contents)
  end
end
