defmodule Tymeslot.GettextCheck.FingerprintTest do
  use ExUnit.Case, async: true

  @moduletag :dev_support
  @moduletag :i18n

  alias Tymeslot.GettextCheck.Fingerprint

  setup do
    root = Path.join(System.tmp_dir!(), "gettext_check_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "priv/gettext/en/LC_MESSAGES"))
    File.mkdir_p!(Path.join(root, "config"))
    on_exit(fn -> File.rm_rf!(root) end)

    write(root, "mix.exs", "defmodule P, do: :ok\n")
    write(root, "mix.lock", "%{}\n")
    write(root, "config/config.exs", "import Config\n")
    write(root, "priv/gettext/default.pot", "msgid \"Hi\"\nmsgstr \"\"\n")
    write(root, "lib/translated.ex", ~s|def a, do: gettext("Hi")\n|)
    write(root, "lib/plain.ex", "def b, do: :ok\n")

    %{root: root}
  end

  defp write(root, path, contents) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, contents)
  end

  defp fingerprint(root), do: Fingerprint.compute(root)

  describe "compute/2" do
    test "is stable across runs over an unchanged tree", %{root: root} do
      assert fingerprint(root) == fingerprint(root)
    end

    test "moves when a file that mentions gettext changes", %{root: root} do
      before = fingerprint(root)
      write(root, "lib/translated.ex", ~s|def a, do: gettext("Hello")\n|)

      refute fingerprint(root) == before
    end

    test "ignores a change to a file that cannot carry a message", %{root: root} do
      before = fingerprint(root)
      write(root, "lib/plain.ex", "def b, do: :error\n")

      assert fingerprint(root) == before
    end

    test "moves when a plain file gains a gettext call", %{root: root} do
      before = fingerprint(root)
      write(root, "lib/plain.ex", ~s|def b, do: gettext("New")\n|)

      refute fingerprint(root) == before
    end

    test "moves when a file that mentions gettext is deleted", %{root: root} do
      before = fingerprint(root)
      File.rm!(Path.join(root, "lib/translated.ex"))

      refute fingerprint(root) == before
    end

    # The path is hashed alongside the contents, so a rename is a change even
    # though every byte of every file survives it.
    test "moves when a file that mentions gettext is renamed", %{root: root} do
      before = fingerprint(root)
      File.rename!(Path.join(root, "lib/translated.ex"), Path.join(root, "lib/renamed.ex"))

      refute fingerprint(root) == before
    end

    test "moves when a catalogue is edited by hand", %{root: root} do
      before = fingerprint(root)
      write(root, "priv/gettext/default.pot", "msgid \"Hi\"\nmsgstr \"\"\n#\n")

      refute fingerprint(root) == before
    end

    test "moves when the project settings or the lock change", %{root: root} do
      before = fingerprint(root)
      write(root, "mix.lock", ~s|%{"gettext" => :other}\n|)
      after_lock = fingerprint(root)
      refute after_lock == before

      write(root, "config/config.exs", "import Config\nconfig :p, :k, 1\n")
      refute fingerprint(root) == after_lock
    end

    test "scans every directory it is given", %{root: root} do
      write(root, "dev/support/helper.ex", ~s|def c, do: gettext("Dev")\n|)
      before = Fingerprint.compute(root, source_dirs: ["lib", "dev/support"])

      write(root, "dev/support/helper.ex", ~s|def c, do: gettext("Dev tools")\n|)

      refute Fingerprint.compute(root, source_dirs: ["lib", "dev/support"]) == before
      assert fingerprint(root) == fingerprint(root)
    end

    test "covers .heex templates, not only .ex sources", %{root: root} do
      write(root, "lib/page.html.heex", ~s|<p>{gettext("Hi")}</p>\n|)
      before = fingerprint(root)

      write(root, "lib/page.html.heex", ~s|<p>{gettext("Hello")}</p>\n|)

      refute fingerprint(root) == before
    end
  end
end
