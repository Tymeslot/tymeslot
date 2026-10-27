defmodule Tymeslot.Utils.DateTimeUtils.Duration do
  @moduledoc "iCalendar and booking-link duration parsing, and URL duration slugs."

  # RFC 5545 §3.3.6 dur-value: sign, weeks, days, then a time part that must
  # name at least one of hours, minutes or seconds when its `T` is present.
  @dur_value ~r/^([+-]?)P(?:(\d+)W)?(?:(\d+)D)?(?:T(?=\d)(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/i
  @unit_seconds [604_800, 86_400, 3600, 60, 1]

  @doc """
  Parses an RFC 5545 duration (§3.3.6) that must not be negative: a length,
  such as an event's `DURATION`. A negative duration is an error, never a
  length counted backwards. `parse_signed/1` reads the whole grammar.

  ## Examples

      iex> Tymeslot.Utils.DateTimeUtils.Duration.parse("PT1H30M")
      {:ok, 5400}  # 1 hour 30 minutes in seconds

      iex> Tymeslot.Utils.DateTimeUtils.Duration.parse("P1DT2H")
      {:ok, 93600} # 1 day and 2 hours in seconds
  """
  @spec parse(String.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def parse(duration_str) when is_binary(duration_str) do
    case parse_signed(duration_str) do
      {:ok, seconds} when seconds < 0 -> {:error, "Negative duration"}
      result -> result
    end
  end

  @doc """
  Parses an RFC 5545 duration (§3.3.6) into signed seconds: an optional `+`
  or `-`, then `P`, weeks or days, and an optional `T` with hours, minutes
  and seconds, in any letter case. A VALARM `TRIGGER` is the usual signed
  one: `-PT15M` is a quarter of an hour before its anchor, `PT15M` after.

  Weeks may be combined with days (`P1W1D`), which the RFC grammar does not
  allow but some servers write. Years and months are not durations in
  iCalendar and are refused.

  ## Examples

      iex> Tymeslot.Utils.DateTimeUtils.Duration.parse_signed("-P1D")
      {:ok, -86400}

      iex> Tymeslot.Utils.DateTimeUtils.Duration.parse_signed("+PT15M")
      {:ok, 900}
  """
  @spec parse_signed(String.t()) :: {:ok, integer()} | {:error, String.t()}
  def parse_signed(duration_str) when is_binary(duration_str) do
    case Regex.run(@dur_value, duration_str) do
      [_match, sign | captures] -> signed_total(sign, captures)
      nil -> {:error, "Invalid duration format"}
    end
  end

  @doc """
  Parses an RFC 5545 duration (§3.3.6) that must not be negative into its
  nominal and exact parts: whole days (weeks counted as seven), and the
  seconds of its time part. Days are nominal, so a caller adds them to a
  calendar date or a wall-clock time and only then the seconds as elapsed
  time; across a DST change `P1D` is one calendar day, not 24 hours.

  ## Examples

      iex> Tymeslot.Utils.DateTimeUtils.Duration.parse_nominal("P1W1DT2H")
      {:ok, {8, 7200}}

      iex> Tymeslot.Utils.DateTimeUtils.Duration.parse_nominal("-P1D")
      {:error, "Negative duration"}
  """
  @spec parse_nominal(String.t()) ::
          {:ok, {days :: non_neg_integer(), seconds :: non_neg_integer()}}
          | {:error, String.t()}
  def parse_nominal(duration_str) when is_binary(duration_str) do
    with {:ok, _seconds} <- parse(duration_str) do
      [_match, _sign | captures] = Regex.run(@dur_value, duration_str)

      [weeks, days, hours, minutes, seconds] =
        captures
        |> Enum.concat(List.duplicate("", 5 - length(captures)))
        |> Enum.map(fn
          "" -> 0
          value -> String.to_integer(value)
        end)

      {:ok, {weeks * 7 + days, hours * 3600 + minutes * 60 + seconds}}
    end
  end

  @doc """
  Parses a meeting length in minutes as booking links and forms write it:
  `"30min"`, `"45 minutes"`, `"60"`. The inverse of `format_for_url/1`.

  ## Examples
      iex> Tymeslot.Utils.DateTimeUtils.Duration.parse_minutes("45min")
      {:ok, 45}

      iex> Tymeslot.Utils.DateTimeUtils.Duration.parse_minutes("soon")
      :error
  """
  @spec parse_minutes(String.t()) :: {:ok, non_neg_integer()} | :error
  def parse_minutes(value) when is_binary(value) do
    case Regex.run(~r/^\s*(\d+)\s*(?:-?\s*min(?:utes?)?)?\s*$/i, value) do
      [_match, minutes] -> {:ok, String.to_integer(minutes)}
      nil -> :error
    end
  end

  @doc """
  Formats duration for URL parameters.

  ## Examples
      iex> Tymeslot.Utils.DateTimeUtils.Duration.format_for_url(15)
      "15min"

      iex> Tymeslot.Utils.DateTimeUtils.Duration.format_for_url(30)
      "30min"
  """
  @spec format_for_url(non_neg_integer()) :: String.t()
  def format_for_url(duration_minutes) when is_integer(duration_minutes) do
    "#{duration_minutes}min"
  end

  # Every component is optional in the pattern, so a bare `P` matches with
  # none captured. `Regex.run/2` leaves out trailing groups that took nothing.
  defp signed_total(sign, captures) do
    components = captures |> Enum.zip(@unit_seconds) |> Enum.reject(&(elem(&1, 0) == ""))

    if components == [] do
      {:error, "Unsupported or invalid duration format"}
    else
      total = Enum.sum_by(components, fn {value, unit} -> String.to_integer(value) * unit end)
      {:ok, if(sign == "-", do: -total, else: total)}
    end
  end
end
