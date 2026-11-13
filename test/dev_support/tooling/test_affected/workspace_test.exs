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

  defp write!(dir, path, contents) do
    file = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, contents)
  end
end
