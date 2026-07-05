defmodule Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder do
  @moduledoc """
  RFC 5545 §3.1 content-line folding.

  Folds content lines to ≤ 75 octets by inserting CRLF + SPACE. The first
  segment is ≤ 75 octets; each continuation is ≤ 74 (the leading SPACE takes
  one octet). Splits happen at UTF-8 codepoint boundaries so multi-byte
  sequences are never torn.
  """

  @doc """
  Folds every content line in an iCal payload to ≤ 75 octets.
  """
  @spec fold_lines(String.t()) :: String.t()
  def fold_lines(ical_string) do
    ical_string
    |> String.split("\r\n")
    |> Enum.map_join("\r\n", &fold_line/1)
  end

  @doc """
  Reverses `fold_lines/1`: splits an iCal payload into logical (unfolded)
  content lines, re-joining any continuation line (one starting with a SPACE
  or TAB per RFC 5545 §3.1) onto its parent. Tolerates bare `\\n` line endings
  in addition to the spec's `\\r\\n`, since not every CalDAV server is strict.
  """
  @spec unfold_lines(String.t()) :: [String.t()]
  def unfold_lines(ical_string) do
    ical_string
    |> String.split(~r/\r\n|\r|\n/)
    |> Enum.reduce([], &unfold_line/2)
    |> Enum.reverse()
  end

  defp unfold_line(line, [] = acc), do: [line | acc]

  defp unfold_line(<<lead, _rest::binary>> = line, [last | rest]) when lead in [?\s, ?\t] do
    [last <> binary_part(line, 1, byte_size(line) - 1) | rest]
  end

  defp unfold_line(line, acc), do: [line | acc]

  defp fold_line(line), do: fold_line_acc(line, _first = true, _acc = [])

  defp fold_line_acc(<<>>, _first, acc), do: acc |> Enum.reverse() |> Enum.join("\r\n ")

  defp fold_line_acc(rest, first, acc) do
    limit = if first, do: 75, else: 74
    {chunk, remaining} = take_octets(rest, limit)
    fold_line_acc(remaining, false, [chunk | acc])
  end

  defp take_octets(binary, max_bytes) when byte_size(binary) <= max_bytes, do: {binary, ""}

  defp take_octets(binary, max_bytes) do
    split_at = safe_utf8_split(binary, max_bytes)
    <<chunk::binary-size(^split_at), rest::binary>> = binary
    {chunk, rest}
  end

  defp safe_utf8_split(binary, pos) do
    pos = min(pos, byte_size(binary))
    retreat_to_boundary(binary, pos)
  end

  defp retreat_to_boundary(_binary, 0), do: 0

  defp retreat_to_boundary(binary, pos) do
    byte = :binary.at(binary, pos - 1)
    if continuation_byte?(byte), do: retreat_to_boundary(binary, pos - 1), else: pos
  end

  defp continuation_byte?(byte), do: byte >= 0x80 and byte <= 0xBF
end
