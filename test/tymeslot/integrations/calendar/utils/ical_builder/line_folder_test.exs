defmodule Tymeslot.Integrations.Calendar.ICalBuilder.LineFolderTest do
  @moduledoc """
  Folding splits a content line at 75 octets (RFC 5545 §3.1) without
  splitting a UTF-8 character: each physical line must be valid UTF-8 on
  its own, since strict parsers decode a line before unfolding it.
  """
  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :integrations
  @moduletag :unit

  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder

  defp physical_lines(folded), do: String.split(folded, "\r\n")

  defp assert_clean_fold(line) do
    folded = LineFolder.fold_lines(line)
    lines = physical_lines(folded)

    assert length(lines) > 1
    assert Enum.reject(lines, &String.valid?/1) == []
    assert Enum.filter(lines, &(byte_size(&1) > 75)) == []
    assert LineFolder.unfold_lines(folded) == [line]
  end

  # 73 ASCII octets, so the emoji's four bytes would cross octet 75.
  test "keeps a four-byte character whole when it would straddle the fold" do
    assert_clean_fold("SUMMARY:" <> String.duplicate("a", 65) <> "😀" <> "tail")
  end

  test "keeps two-byte characters whole on every folded line" do
    assert_clean_fold("DESCRIPTION:" <> String.duplicate("ü", 40))
  end

  test "folds ASCII at exactly 75 octets, then 74 after the leading space" do
    line = "DESCRIPTION:" <> String.duplicate("x", 200)

    assert line |> LineFolder.fold_lines() |> physical_lines() |> Enum.map(&byte_size/1) ==
             [75, 75, 64]
  end

  # Continuation bytes with no character start among them, as a value that is
  # not valid UTF-8 carries: there is no boundary to retreat to.
  test "folds bytes with no character boundary at the limit instead of looping" do
    line = :binary.copy(<<0x80>>, 200)

    task = Task.async(fn -> LineFolder.fold_lines(line) end)
    folded = Task.await(task, 1_000)

    assert folded |> String.split("\r\n") |> Enum.map(&byte_size/1) == [75, 75, 52]
  end
end
