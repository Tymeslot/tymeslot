defmodule Mix.Tasks.SetVersionTest do
  use ExUnit.Case, async: true

  @moduletag :utils
  @moduletag :tmp_dir

  alias Mix.Tasks.SetVersion

  @mix_exs """
  defmodule Example.MixProject do
    use Mix.Project

    def project do
      [
        app: :example,
        version: "1.2.3",
        elixir: "~> 1.20"
      ]
    end
  end
  """

  describe "write_version/2" do
    test "rewrites the project version", %{tmp_dir: dir} do
      path = write_mix_exs(dir, @mix_exs)

      assert SetVersion.write_version(path, "1.3.0") == :updated

      assert File.read!(path) ==
               String.replace(@mix_exs, ~s(version: "1.2.3"), ~s(version: "1.3.0"))
    end

    test "leaves the file alone when the version is already set", %{tmp_dir: dir} do
      path = write_mix_exs(dir, @mix_exs)

      assert SetVersion.write_version(path, "1.2.3") == :unchanged
      assert File.read!(path) == @mix_exs
    end

    test "rewrites only the first version line", %{tmp_dir: dir} do
      contents = @mix_exs <> ~s(# pinned elsewhere: version: "0.1.0"\n)
      path = write_mix_exs(dir, contents)

      SetVersion.write_version(path, "2.0.0")

      assert File.read!(path) =~ ~s(version: "2.0.0",)
      assert File.read!(path) =~ ~s(# pinned elsewhere: version: "0.1.0")
    end

    test "raises when the file has no version line", %{tmp_dir: dir} do
      path = write_mix_exs(dir, "defmodule Example.MixProject do\nend\n")

      assert_raise Mix.Error, ~r/No version: "X\.Y\.Z" line/, fn ->
        SetVersion.write_version(path, "1.3.0")
      end
    end
  end

  describe "run/1" do
    test "rejects a version that is not semver" do
      assert_raise Mix.Error, ~r/Invalid version format/, fn -> SetVersion.run(["1.3"]) end
    end

    test "requires exactly one argument" do
      assert_raise Mix.Error, ~r/Usage: mix set_version VERSION/, fn -> SetVersion.run([]) end
    end
  end

  defp write_mix_exs(dir, contents) do
    path = Path.join(dir, "mix.exs")
    File.write!(path, contents)
    path
  end
end
