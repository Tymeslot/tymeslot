defmodule Tymeslot.Integrations.Calendar.ICalBuilder.ContentLines do
  @moduledoc """
  Reading and writing a stored iCalendar document as a list of logical
  content lines (RFC 5545 §3.1), for the modules that edit such a document in
  place rather than serialising a new one (`ICalBuilder.Patcher`,
  `ICalBuilder.Series`).

  Lines are unfolded on the way in and folded again on the way out, so an
  edit works on whole properties and every line it leaves alone goes back to
  the server with its content unchanged.
  """

  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder

  @doc """
  Splits `document` into unfolded content lines, dropping blank ones.
  """
  @spec split(String.t()) :: [String.t()]
  def split(document) when is_binary(document) do
    document
    |> LineFolder.unfold_lines()
    |> Enum.reject(&(&1 == ""))
  end

  @doc """
  Joins content lines back into a document: CRLF-terminated and folded to 75
  octets per RFC 5545 §3.1.
  """
  @spec join([String.t()]) :: String.t()
  def join(lines) when is_list(lines) do
    lines
    |> Enum.join("\r\n")
    |> Kernel.<>("\r\n")
    |> LineFolder.fold_lines()
  end

  @doc """
  Splits `lines` at the first `terminator`, returning the lines before it and
  the lines after it; the terminator itself is dropped. Without a terminator,
  every line is taken.
  """
  @spec take_until([String.t()], String.t(), [String.t()]) :: {[String.t()], [String.t()]}
  def take_until(lines, terminator, acc \\ [])
  def take_until([], _terminator, acc), do: {Enum.reverse(acc), []}
  def take_until([terminator | rest], terminator, acc), do: {Enum.reverse(acc), rest}
  def take_until([line | rest], terminator, acc), do: take_until(rest, terminator, [line | acc])

  @doc """
  The upcased property name of a content line. It runs to the first parameter
  separator or the value separator, whichever comes first (RFC 5545 §3.1).
  """
  @spec property_name(String.t()) :: String.t()
  def property_name(line) do
    line
    |> String.split([";", ":"], parts: 2)
    |> hd()
    |> String.upcase()
  end

  # A parameter value may be quoted, and a quoted one may hold a colon
  # (`ALTREP="http://..."`), so the value separator is the first colon outside
  # quotes rather than simply the first colon.
  @name_and_params ~r/^([^:"]*(?:"[^"]*"[^:"]*)*):(.*)$/s

  @doc """
  Splits a content line into its name with parameters and its value:
  `"DTSTART;TZID=Europe/Berlin:20260504T100000"` gives
  `{"DTSTART;TZID=Europe/Berlin", "20260504T100000"}`. A line without a value
  separator gives `{line, ""}`.
  """
  @spec split_value(String.t()) :: {String.t(), String.t()}
  def split_value(line) do
    case Regex.run(@name_and_params, line) do
      [_line, name_and_params, value] -> {name_and_params, value}
      nil -> {line, ""}
    end
  end

  @doc """
  The first line in `lines` whose property is `name` (upcased), or `nil`.
  """
  @spec find(String.t(), [String.t()]) :: String.t() | nil
  def find(name, lines) do
    Enum.find(lines, &(property_name(&1) == name))
  end
end
