defmodule Tymeslot.Infrastructure.DotenvLoaderTest do
  use ExUnit.Case, async: false
  @moduletag :infrastructure

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Tymeslot.Infrastructure.DotenvLoader
  alias Tymeslot.Test.LogCapture

  # The grammar both readers of a `.env` implement, written out line by line.
  # `scripts/dotenv-reader.sh` is the specification; this fixture is fed to
  # both it and `DotenvLoader` by the agreement test below, so every line here
  # is a case the two have to resolve to the same bytes. Keys share a prefix so
  # the shell harness can be handed a clean environment and still be told which
  # variables came from the file.
  @agreement_lines [
    "# a comment",
    "   # an indented comment",
    "",
    "AGREE_PLAIN=Plain",
    "AGREE_UTF8=Müller",
    "AGREE_EMOJI=café☕",
    "AGREE_CJK=東京",
    "export AGREE_EXPORTED=exported",
    "AGREE_DQ_UTF8=\"Müller\"",
    "AGREE_SQ_UTF8='Müller'",
    "AGREE_DQ_ESCAPES=\"line\\nbreak\\ttab\"",
    "AGREE_DQ_FORM_FEED=\"a\\fb\\bc\\rd\"",
    "AGREE_DQ_UNICODE=\"M\\u00FCller \\u6771\\u4EAC\"",
    "AGREE_DQ_SPECIALS=\"p@ss \\\"q\\\" \\\\ \\$x\"",
    "AGREE_DQ_UNKNOWN_ESCAPE=\"a\\zb\"",
    "AGREE_SQ_LITERAL='p@ss #1 $x \\ \"q\"'",
    "AGREE_BARE_HASH=p#ss",
    "AGREE_BARE_BACKSLASH=C:\\path",
    "AGREE_BARE_DOLLAR=$HOME and $(id)",
    "AGREE_BARE_COMMENT=value # trailing comment",
    # Written as a concatenation so the trailing spaces survive an editor.
    "AGREE_BARE_TRAILING_SPACE=value" <> "   ",
    # An ideographic space (U+3000) is not ASCII whitespace, so neither
    # reader may treat it as one, even though bash's `[[:space:]]` does under
    # a `LANG=C.UTF-8` locale, which is what production runs the reader in.
    "AGREE_CJK_SPACE_COMMENT=value" <> "　" <> "# trailing comment",
    "AGREE_CJK_TRAILING_SPACE=value" <> "　",
    "AGREE_SPACED_KEY = spaced",
    "AGREE_EMPTY=",
    "AGREE_EMPTY_DQ=\"\"",
    "AGREE_EMPTY_SQ=''",
    "AGREE_DUP=first",
    "AGREE_DUP=second",
    "AGREE_DQ_COMMENT=\"quoted\" # trailing comment",
    "AGREE_SQ_COMMENT='quoted' # trailing comment",
    "AGREE_DQ_TRAILING_SPACE=\"quoted\"" <> "   ",
    "AGREE_DQ_HASH_INSIDE=\"a # b\" # c",
    "AGREE_DQ_ESCAPED_QUOTE_COMMENT=\"a\\\"b\" # c",
    "AGREE_EMPTY_COMMENT= # leave blank",
    "AGREE_BARE_LEADING_HASH=#literal",
    # Every line below is one both readers reject.
    "AGREE_DQ_TRAILING_TEXT=\"a\" b",
    "AGREE_SQ_TRAILING_TEXT='a' b",
    "AGREE_UNTERMINATED=\"never closed",
    "AGREE_TRAILING_BACKSLASH=\"ends\\\"",
    "AGREE_BAD_UNICODE=\"a\\uZZZZb\"",
    "AGREE_INNER_QUOTE=\"a\"b\"",
    "AGREE_SQ_INNER_QUOTE='a'b'",
    "9AGREE_BAD_KEY=nope",
    "export  AGREE_DOUBLE_SPACE=nope",
    "AGREE-BAD-KEY=nope",
    "AGREE_LINE WITHOUT EQUALS"
  ]

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "dotenv_loader_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    keys =
      ~w(
        TYMESLOT_DOTENV_TEST_A TYMESLOT_DOTENV_TEST_B TYMESLOT_DOTENV_TEST_SHELL
        TYMESLOT_DOTENV_TEST_MALFORMED TYMESLOT_DOTENV_TEST_ASCII
        TYMESLOT_DOTENV_TEST_EMAIL_FROM_NAME TYMESLOT_DOTENV_TEST_QUOTED_NAME
        TYMESLOT_DOTENV_TEST_SINGLE_NAME TYMESLOT_DOTENV_TEST_EMOJI
        TYMESLOT_DOTENV_TEST_CJK
      ) ++ agreement_keys()

    Enum.each(keys, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(keys, &System.delete_env/1)
      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  test "populates unset keys from the .env file", %{tmp_dir: tmp_dir} do
    path = write_env(tmp_dir, "TYMESLOT_DOTENV_TEST_A=from_file\n")

    assert :ok = DotenvLoader.load([path])
    assert System.get_env("TYMESLOT_DOTENV_TEST_A") == "from_file"
  end

  test "shell-supplied values win over .env entries", %{tmp_dir: tmp_dir} do
    path = write_env(tmp_dir, "TYMESLOT_DOTENV_TEST_SHELL=from_file\n")
    System.put_env("TYMESLOT_DOTENV_TEST_SHELL", "from_shell")

    assert :ok = DotenvLoader.load([path])
    assert System.get_env("TYMESLOT_DOTENV_TEST_SHELL") == "from_shell"
  end

  # An entry the environment overrides has no effect, and used to say nothing
  # about it. Named, never valued: the value may be a secret.
  test "names a key the environment overrides with a different value", %{tmp_dir: tmp_dir} do
    path = write_env(tmp_dir, "TYMESLOT_DOTENV_TEST_SHELL=file_secret\n")
    System.put_env("TYMESLOT_DOTENV_TEST_SHELL", "shell_secret")

    messages = warning_messages(fn -> DotenvLoader.load([path]) end)

    assert [message] = Enum.filter(messages, &(&1 =~ "TYMESLOT_DOTENV_TEST_SHELL"))
    refute message =~ "secret"
  end

  # The container entrypoints apply the file before the release does, so every
  # key arrives already set to the file's own value.
  test "says nothing about a key the environment already holds at the file's value", %{
    tmp_dir: tmp_dir
  } do
    path = write_env(tmp_dir, "TYMESLOT_DOTENV_TEST_SHELL=same\n")
    System.put_env("TYMESLOT_DOTENV_TEST_SHELL", "same")

    messages = warning_messages(fn -> DotenvLoader.load([path]) end)

    assert Enum.filter(messages, &(&1 =~ "TYMESLOT_DOTENV_TEST_SHELL")) == []
  end

  test "earlier files in the list win over later files", %{tmp_dir: tmp_dir} do
    primary = Path.join(tmp_dir, ".env")
    secondary = Path.join(tmp_dir, ".env.fallback")
    File.write!(primary, "TYMESLOT_DOTENV_TEST_B=primary\n")
    File.write!(secondary, "TYMESLOT_DOTENV_TEST_B=secondary\n")

    messages = warning_messages(fn -> DotenvLoader.load([primary, secondary]) end)

    assert System.get_env("TYMESLOT_DOTENV_TEST_B") == "primary"
    # The earlier file set it, not the environment, so nothing was overridden.
    assert Enum.filter(messages, &(&1 =~ "TYMESLOT_DOTENV_TEST_B")) == []
  end

  defp warning_messages(fun) do
    LogCapture.with_capture(fun)

    LogCapture.drain()
    |> Enum.filter(&(&1.level == :warning))
    |> Enum.map(&LogCapture.message_text(&1.msg))
  end

  # The round-trip table this parser exists for. Every row used to come back as
  # mangled bytes and be dropped; every row must now arrive intact.
  test "non-ASCII values survive bare, double-quoted and single-quoted", %{tmp_dir: tmp_dir} do
    path =
      write_env(tmp_dir, """
      TYMESLOT_DOTENV_TEST_EMAIL_FROM_NAME=Müller
      TYMESLOT_DOTENV_TEST_QUOTED_NAME="Müller"
      TYMESLOT_DOTENV_TEST_SINGLE_NAME='Müller'
      TYMESLOT_DOTENV_TEST_EMOJI=café☕
      TYMESLOT_DOTENV_TEST_CJK=東京
      TYMESLOT_DOTENV_TEST_ASCII=Plain
      """)

    assert :ok = DotenvLoader.load([path])

    assert System.get_env("TYMESLOT_DOTENV_TEST_EMAIL_FROM_NAME") == "Müller"
    assert System.get_env("TYMESLOT_DOTENV_TEST_QUOTED_NAME") == "Müller"
    assert System.get_env("TYMESLOT_DOTENV_TEST_SINGLE_NAME") == "Müller"
    assert System.get_env("TYMESLOT_DOTENV_TEST_EMOJI") == "café☕"
    assert System.get_env("TYMESLOT_DOTENV_TEST_CJK") == "東京"
    assert System.get_env("TYMESLOT_DOTENV_TEST_ASCII") == "Plain"
  end

  test "\\uXXXX escapes resolve to the same characters as the raw bytes", %{tmp_dir: tmp_dir} do
    path =
      write_env(tmp_dir, """
      TYMESLOT_DOTENV_TEST_A="M\\u00FCller"
      TYMESLOT_DOTENV_TEST_B="\\u6771\\u4EAC"
      """)

    assert :ok = DotenvLoader.load([path])
    assert System.get_env("TYMESLOT_DOTENV_TEST_A") == "Müller"
    assert System.get_env("TYMESLOT_DOTENV_TEST_B") == "東京"
  end

  test "a value whose bytes are not valid UTF-8 is skipped without taking the file with it",
       %{tmp_dir: tmp_dir} do
    # A file saved as Latin-1 rather than UTF-8: `Müller` as <<77, 252, ...>>.
    # `System.put_env/2` raises on that, and a raise here would take down every
    # boot that reads the file, so the key is skipped and the rest applied.
    path = Path.join(tmp_dir, ".env")

    File.write!(
      path,
      <<"TYMESLOT_DOTENV_TEST_A=M", 252, "ller\nTYMESLOT_DOTENV_TEST_ASCII=plain\n">>
    )

    log = capture_log(fn -> assert :ok = DotenvLoader.load([path]) end)

    assert System.get_env("TYMESLOT_DOTENV_TEST_A") == nil
    assert System.get_env("TYMESLOT_DOTENV_TEST_ASCII") == "plain"
    assert log =~ "TYMESLOT_DOTENV_TEST_A"
  end

  test "a value containing a raw NUL byte is skipped without taking the file with it",
       %{tmp_dir: tmp_dir} do
    # A raw NUL is valid UTF-8, so `String.valid?/1` alone would let it through,
    # but `System.put_env/2` raises `ArgumentError` on it, which would take
    # down boot. It must be skipped like invalid UTF-8, not raise.
    path = Path.join(tmp_dir, ".env")

    File.write!(
      path,
      <<"TYMESLOT_DOTENV_TEST_A=a", 0, "b\nTYMESLOT_DOTENV_TEST_ASCII=plain\n">>
    )

    log = capture_log(fn -> assert :ok = DotenvLoader.load([path]) end)

    assert System.get_env("TYMESLOT_DOTENV_TEST_A") == nil
    assert System.get_env("TYMESLOT_DOTENV_TEST_ASCII") == "plain"
    assert log =~ "TYMESLOT_DOTENV_TEST_A"
  end

  # The agreement test cannot catch a case both readers get wrong the same way,
  # so the comment forms an existing `.env` commonly uses are pinned outright.
  test "a comment after a quoted value or an empty one is not part of the value",
       %{tmp_dir: tmp_dir} do
    path =
      write_env(tmp_dir, """
      TYMESLOT_DOTENV_TEST_A="quoted # inside" # trailing comment
      TYMESLOT_DOTENV_TEST_B='single' # trailing comment
      TYMESLOT_DOTENV_TEST_ASCII= # leave blank
      TYMESLOT_DOTENV_TEST_CJK=#literal
      TYMESLOT_DOTENV_TEST_MALFORMED="quoted" trailing text
      """)

    log = capture_log(fn -> assert :ok = DotenvLoader.load([path]) end)

    assert System.get_env("TYMESLOT_DOTENV_TEST_A") == "quoted # inside"
    assert System.get_env("TYMESLOT_DOTENV_TEST_B") == "single"
    assert System.get_env("TYMESLOT_DOTENV_TEST_ASCII") == ""
    assert System.get_env("TYMESLOT_DOTENV_TEST_CJK") == "#literal"
    assert System.get_env("TYMESLOT_DOTENV_TEST_MALFORMED") == nil
    assert log =~ "line 5"
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

    log = capture_log(fn -> assert :ok = DotenvLoader.load([path]) end)

    assert System.get_env("TYMESLOT_DOTENV_TEST_MALFORMED") == nil
    assert log =~ "line 1"
  end

  # The property the in-house parser exists to establish: the file is read by
  # two implementations, the entrypoints' shell reader before the release boots and this module
  # once it has, and a value that differs between them is a value the operator
  # cannot reason about. Rather than assert a hand-written expectation twice,
  # this runs the real shell reader over the same fixture and compares.
  test "agrees with the shell reader's load_env_file byte for byte", %{tmp_dir: tmp_dir} do
    contents = Enum.join(@agreement_lines, "\n") <> "\n"
    path = write_env(tmp_dir, contents)

    shell = shell_load(tmp_dir, path)

    assert :ok = DotenvLoader.load([path])

    # Guards against a harness that silently applied nothing and so agreed with
    # an equally empty Elixir side.
    assert map_size(shell) > 20

    # Agreement alone would pass if both readers dropped these, as they once did.
    assert shell["AGREE_DQ_COMMENT"] == "quoted"
    assert shell["AGREE_SQ_COMMENT"] == "quoted"
    assert shell["AGREE_DQ_ESCAPED_QUOTE_COMMENT"] == "a\"b"
    assert shell["AGREE_EMPTY_COMMENT"] == ""
    refute Map.has_key?(shell, "AGREE_DQ_TRAILING_TEXT")

    assert loaded_agreement_keys() == shell
  end

  defp loaded_agreement_keys do
    agreement_keys()
    |> Enum.flat_map(fn key ->
      case System.get_env(key) do
        nil -> []
        value -> [{key, value}]
      end
    end)
    |> Map.new()
  end

  # A file edited on Windows and pushed in with `cloudron push`. Each reader
  # strips one trailing carriage return per line; neither may leave one inside
  # a value, and a quoted value must still be seen to close.
  test "agrees with the shell reader on a file with CRLF line endings", %{tmp_dir: tmp_dir} do
    contents = Enum.join(@agreement_lines, "\r\n") <> "\r\n"
    path = write_env(tmp_dir, contents)

    shell = shell_load(tmp_dir, path)

    assert :ok = DotenvLoader.load([path])

    assert map_size(shell) > 20

    # Agreeing on a carriage return left inside every value would be agreement
    # of the wrong kind, so pin one value outright.
    assert shell["AGREE_PLAIN"] == "Plain"
    assert shell["AGREE_DQ_UTF8"] == "Müller"

    assert loaded_agreement_keys() == shell
  end

  defp write_env(tmp_dir, contents) do
    path = Path.join(tmp_dir, ".env")
    File.write!(path, contents)
    path
  end

  # Every `AGREE_`-prefixed token the fixture mentions, valid keys and rejected
  # ones alike, so the comparison notices a key one reader applies and the
  # other does not.
  defp agreement_keys do
    @agreement_lines
    |> Enum.flat_map(fn line ->
      Regex.run(~r/^\s*(?:export\s+)?([^\s=]+)/, line, capture: :all_but_first) || []
    end)
    |> Enum.filter(&String.contains?(&1, "AGREE"))
    |> Enum.uniq()
  end

  # Runs the fixture through the shell reader both container entrypoints
  # source. The file defines functions only, so it is sourced whole.
  defp shell_load(tmp_dir, env_path) do
    reader = Path.expand("../../../scripts/dotenv-reader.sh", __DIR__)

    harness = Path.join(tmp_dir, "harness.sh")

    File.write!(harness, """
    set -eu
    . #{reader}
    loaded_keys=""
    load_env_file "$1"
    for shell_harness_key in $loaded_keys; do
      printf '%s\\0%s\\0' "$shell_harness_key" "${!shell_harness_key}"
    done
    """)

    # The child gets an empty environment, every inherited variable cleared, so
    # nothing the test runner holds can shadow a fixture key and quietly turn a
    # disagreement into a skipped line; then `LANG` is set to `C.UTF-8`, the
    # locale Dockerfile.cloudron's runtime stage exports and `start.sh` runs
    # under in production. Leaving the child on the implicit POSIX "C" locale
    # would make bash's `[[:space:]]` byte-oriented for free and hide any
    # divergence that only shows up under the locale that actually ships. The
    # harness needs no PATH; bash is named absolutely and it uses only
    # builtins.
    cleared =
      System.get_env()
      |> Enum.map(fn {name, _value} -> {name, nil} end)
      |> Kernel.++([{"LANG", "C.UTF-8"}])

    {output, 0} = System.cmd("/bin/bash", [harness, env_path], env: cleared)

    output
    |> :binary.split(<<0>>, [:global])
    |> Enum.chunk_every(2)
    |> Enum.flat_map(fn
      [key, value] -> [{key, value}]
      _trailing -> []
    end)
    |> Map.new()
  end
end
