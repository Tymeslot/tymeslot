defmodule Tymeslot.Infrastructure.DotenvLoaderTest do
  use ExUnit.Case, async: false
  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.DotenvLoader

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "dotenv_loader_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    keys =
      ~w(TYMESLOT_DOTENV_TEST_A TYMESLOT_DOTENV_TEST_B TYMESLOT_DOTENV_TEST_SHELL TYMESLOT_DOTENV_TEST_MALFORMED)

    Enum.each(keys, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(keys, &System.delete_env/1)
      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  test "populates unset keys from the .env file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, ".env")
    File.write!(path, "TYMESLOT_DOTENV_TEST_A=from_file\n")

    assert :ok = DotenvLoader.load([path])
    assert System.get_env("TYMESLOT_DOTENV_TEST_A") == "from_file"
  end

  test "shell-supplied values win over .env entries", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, ".env")
    File.write!(path, "TYMESLOT_DOTENV_TEST_SHELL=from_file\n")
    System.put_env("TYMESLOT_DOTENV_TEST_SHELL", "from_shell")

    assert :ok = DotenvLoader.load([path])
    assert System.get_env("TYMESLOT_DOTENV_TEST_SHELL") == "from_shell"
  end

  test "earlier files in the list win over later files", %{tmp_dir: tmp_dir} do
    primary = Path.join(tmp_dir, ".env")
    secondary = Path.join(tmp_dir, ".env.fallback")
    File.write!(primary, "TYMESLOT_DOTENV_TEST_B=primary\n")
    File.write!(secondary, "TYMESLOT_DOTENV_TEST_B=secondary\n")

    assert :ok = DotenvLoader.load([primary, secondary])
    assert System.get_env("TYMESLOT_DOTENV_TEST_B") == "primary"
  end

  test "missing files are silently skipped" do
    assert :ok = DotenvLoader.load(["/nonexistent/path/.env"])
  end

  test "an empty path list is a no-op" do
    assert :ok = DotenvLoader.load([])
  end

  test "malformed .env content logs a warning and does not raise", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, ".env.malformed")
    File.write!(path, "INVALID LINE WITHOUT EQUALS\n")

    assert :ok = DotenvLoader.load([path])
    assert System.get_env("TYMESLOT_DOTENV_TEST_MALFORMED") == nil
  end
end
