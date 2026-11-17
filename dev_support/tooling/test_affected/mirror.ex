defmodule Tymeslot.TestAffected.Mirror do
  @moduledoc """
  Maps a source path to the tests that mirror it: `lib/x` to `test/x`, and the
  dev tooling and Credo checks in `dev_support/x` to `test/dev_support/x`.
  Part of `Tymeslot.TestAffected.Selection`.
  """

  alias Tymeslot.TestAffected.Selection

  @source_extensions [".html.heex", ".heex", ".ex"]

  @doc """
  Resolves a lib path to the test files the selection is seeded from.

  The mirror *file* is preferred over the mirror directory. It carries the same
  domain tags, so the tag sweep that does the real work is unchanged, while the
  seed stops dragging in every sibling: measured over 156 commits that is 15%
  of the suite rather than 26%, for six tenths of a point of recall. The
  directory only stands in when no mirror file exists, which is also what stops
  a top-level context module seeding itself with the whole of `test/tymeslot`.
  """
  @spec mirror(String.t(), Selection.index()) :: {[String.t()], String.t()} | nil
  def mirror(path, index) do
    case mirror_file(path, index) do
      nil -> mirror_from_dir(path, index)
      file -> {[file], file}
    end
  end

  @doc """
  The test files of `path`'s mirror directory, the deepest existing one, and
  the directory, or `nil` when the walk reaches a top-level test root.
  """
  @spec mirror_from_dir(String.t(), Selection.index()) :: {[String.t()], String.t()} | nil
  def mirror_from_dir(path, index) do
    case mirror_dir(path, index) do
      nil -> nil
      dir -> {Enum.filter(index.test_files, &in_dir?(&1, dir)), dir <> "/"}
    end
  end

  @doc """
  Maps a lib path to its mirror test file, when one exists.

  `lib/tymeslot/auth/oauth/google.ex` mirrors to
  `test/tymeslot/auth/oauth/google_test.exs`.
  """
  @spec mirror_file(String.t(), Selection.index()) :: String.t() | nil
  def mirror_file(path, index) do
    candidate =
      path
      |> test_dir()
      |> strip_source_extension()
      |> Kernel.<>("_test.exs")

    if MapSet.member?(index.test_files, candidate), do: candidate
  end

  # `.html.heex` first: a colocated template belongs to its LiveView, so
  # `foo_live.html.heex` should find `foo_live_test.exs` rather than look for a
  # test named after the template.
  defp strip_source_extension(path) do
    Enum.find_value(@source_extensions, path, fn ext ->
      if String.ends_with?(path, ext), do: String.replace_suffix(path, ext, "")
    end)
  end

  # Maps a lib path to the deepest existing mirror test directory.
  #
  # `lib/tymeslot/auth/oauth/google.ex` mirrors to `test/tymeslot/auth/oauth`,
  # walking up a segment at a time when a directory has no counterpart. Around a
  # third of lib directories do not mirror exactly, so the walk matters; it stops
  # at `test/` rather than selecting the whole suite by accident.
  defp mirror_dir(path, index) do
    path
    |> Path.dirname()
    |> test_dir()
    |> walk_up(index)
  end

  defp test_dir("lib/" <> rest), do: "test/" <> rest
  defp test_dir("dev_support/" <> rest), do: "test/dev_support/" <> rest
  defp test_dir(path), do: path

  defp walk_up("test", _index), do: nil
  defp walk_up(".", _index), do: nil

  defp walk_up(dir, index) when is_binary(dir) do
    cond do
      # `test/tymeslot` or `test/tymeslot_web` is not a mirror of anything, it
      # is most of the suite. Widening honestly beats a selection that only
      # looks targeted.
      root?(dir) -> nil
      dir_populated?(dir, index) -> dir
      true -> dir |> Path.dirname() |> walk_up(index)
    end
  end

  defp root?(dir), do: dir |> Path.split() |> length() <= 2

  defp dir_populated?(dir, index), do: Enum.any?(index.test_files, &in_dir?(&1, dir))

  @doc "Whether `file` sits anywhere under `dir`."
  @spec in_dir?(String.t(), String.t()) :: boolean()
  def in_dir?(file, dir), do: String.starts_with?(file, dir <> "/")
end
