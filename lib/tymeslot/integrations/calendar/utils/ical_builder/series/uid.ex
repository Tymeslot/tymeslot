defmodule Tymeslot.Integrations.Calendar.ICalBuilder.Series.Uid do
  @moduledoc """
  Giving a recurring event's CalDAV resource a new identifier: the `UID` of
  every `VEVENT` in it, the master and each override alike, replaced by one
  new value. The public entry point is `ICalBuilder.Series.reuid/2`; a
  split's tail (`Series.Split`) is renamed here too.

  The document is rewritten as text rather than read as components, so the
  copy is the server's document byte for byte apart from those lines: a
  line the server folded somewhere other than where `Series.Document` would
  fold it stays as it was, and so do its line endings. A `UID` inside a
  subcomponent is the subcomponent's own (an alarm's, RFC 9074) and is left
  alone.
  """

  alias Tymeslot.Integrations.Calendar.ICalBuilder.ContentLines
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Format
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Series.Document

  @doc """
  A new uid for a copy of `document`'s series, of the same origin as the
  uid it replaces (`Format.uid_origin/1`). The CalDAV sync reads ownership
  off the uid alone, so a copy of somebody else's series given a Tymeslot
  uid would be taken for Tymeslot's.
  """
  @spec successor(String.t()) :: String.t()
  def successor(document) do
    document
    |> Document.components()
    |> Enum.find_value(&own_uid/1)
    |> Format.uid_origin()
    |> Format.generate_uid()
  end

  defp own_uid({:vevent, items}) do
    case ContentLines.find("UID", Document.properties(items)) do
      nil -> nil
      line -> line |> ContentLines.split_value() |> elem(1) |> String.trim()
    end
  end

  defp own_uid(_line), do: nil

  @doc """
  `document` with the `UID` of every `VEVENT` replaced by `uid`, or `:empty`
  when it holds no `VEVENT`.
  """
  @spec put(String.t(), String.t()) :: {:ok, String.t()} | :empty
  def put(document, uid) do
    replacement = "UID:" <> uid

    {lines, state} =
      document
      |> String.split(~r/(?<=\n)/)
      |> Enum.flat_map_reduce(
        %{stack: [], replaced: false, vevents: 0},
        &line(&1, &2, replacement)
      )

    if state.vevents > 0, do: {:ok, IO.iodata_to_binary(lines)}, else: :empty
  end

  # A continuation belongs to the line before it, so it goes with a UID
  # line that was replaced.
  defp line(<<lead, _rest::binary>>, %{replaced: true} = state, _replacement)
       when lead in [?\s, ?\t],
       do: {[], state}

  defp line(<<lead, _rest::binary>> = raw, state, _replacement) when lead in [?\s, ?\t],
    do: {[raw], state}

  defp line(raw, state, replacement) do
    {content, ending} = split_ending(raw)
    state = %{state | replaced: false}

    case {String.upcase(content), state.stack} do
      {"BEGIN:VEVENT", stack} ->
        {[raw], %{state | stack: ["VEVENT" | stack], vevents: state.vevents + 1}}

      {"BEGIN:" <> name, stack} ->
        {[raw], %{state | stack: [name | stack]}}

      {"END:" <> _name, [_top | stack]} ->
        {[raw], %{state | stack: stack}}

      {upcased, ["VEVENT" | _outer]} ->
        if property_name(upcased) == "UID",
          do: {[fold(replacement), ending], %{state | replaced: true}},
          else: {[raw], state}

      _other ->
        {[raw], state}
    end
  end

  defp split_ending(raw) do
    cond do
      String.ends_with?(raw, "\r\n") -> {binary_part(raw, 0, byte_size(raw) - 2), "\r\n"}
      String.ends_with?(raw, "\n") -> {binary_part(raw, 0, byte_size(raw) - 1), "\n"}
      true -> {raw, ""}
    end
  end

  defp property_name(line), do: line |> String.split([":", ";"], parts: 2) |> hd()

  defp fold(line), do: LineFolder.fold_lines(line)
end
