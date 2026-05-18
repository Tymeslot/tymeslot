defmodule Tymeslot.Utils.DateTimeUtils.Duration do
  @moduledoc "Duration parsing and human-readable formatting."

  @doc """
  Parses an ISO 8601 duration string (simplified).
  Supports both time durations (PT1H) and day durations (P1D).

  ## Examples

      iex> Tymeslot.Utils.DateTimeUtils.Duration.parse("PT1H30M")
      {:ok, 5400}  # 1 hour 30 minutes in seconds

      iex> Tymeslot.Utils.DateTimeUtils.Duration.parse("P1D")
      {:ok, 86400} # 1 day in seconds
  """
  @spec parse(String.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def parse(duration_str) when is_binary(duration_str) do
    cond do
      # Time duration: PT1H30M
      String.starts_with?(duration_str, "PT") ->
        parse_time_duration(duration_str)

      # Day duration: P1D or P1W
      String.starts_with?(duration_str, "P") ->
        parse_day_duration(duration_str)

      true ->
        {:error, "Invalid duration format"}
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

  @doc """
  Formats duration string or integer for display.
  """
  @spec format(term()) :: String.t()
  def format(duration) when is_integer(duration) do
    format_minutes(duration)
  end

  def format(duration_string) when is_binary(duration_string) do
    case Regex.run(~r/^\s*(\d+)\s*(?:-?\s*min(?:utes?)?)?\s*$/i, duration_string) do
      [_match, minutes_str] ->
        minutes_str |> String.to_integer() |> format_minutes()

      _result ->
        "Unknown duration"
    end
  end

  def format(_value), do: "Unknown duration"

  defp parse_time_duration(duration_str) do
    case Regex.run(~r/^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$/, duration_str) do
      [_match | captures] ->
        hours = parse_duration_component(Enum.at(captures, 0), 3600)
        minutes = parse_duration_component(Enum.at(captures, 1), 60)
        seconds = parse_duration_component(Enum.at(captures, 2), 1)

        if hours + minutes + seconds > 0 or duration_str == "PT0S" do
          {:ok, hours + minutes + seconds}
        else
          {:error, "Invalid time duration values"}
        end

      _no_match ->
        {:error, "Invalid time duration format"}
    end
  end

  defp parse_day_duration(duration_str) do
    case Regex.run(~r/^P(?:(\d+)W)?(?:(\d+)D)?$/, duration_str) do
      [_match | captures] ->
        weeks = parse_duration_component(Enum.at(captures, 0), 86_400 * 7)
        days = parse_duration_component(Enum.at(captures, 1), 86_400)
        total = weeks + days

        # Accept zero durations if the format is valid (regex matched)
        # and at least one component is present (not just "P")
        if total > 0 or duration_str != "P" do
          {:ok, total}
        else
          {:error, "Unsupported or invalid duration format"}
        end

      _no_match ->
        {:error, "Invalid day/week duration format or unsupported components"}
    end
  end

  defp parse_duration_component(nil, _multiplier), do: 0
  defp parse_duration_component("", _multiplier), do: 0

  defp parse_duration_component(value, multiplier) do
    String.to_integer(value) * multiplier
  end

  defp format_minutes(1), do: "1 minute"
  defp format_minutes(minutes) when minutes < 60, do: "#{minutes} minutes"
  defp format_minutes(60), do: "1 hour"
  defp format_minutes(90), do: "1.5 hours"
  defp format_minutes(120), do: "2 hours"
  defp format_minutes(minutes) when rem(minutes, 60) == 0, do: "#{div(minutes, 60)} hours"

  defp format_minutes(minutes) do
    hours = div(minutes, 60)
    mins = rem(minutes, 60)
    hour_text = "#{hours} hour#{if hours > 1, do: "s", else: ""}"
    minute_text = "#{mins} minute#{if mins > 1, do: "s", else: ""}"
    "#{hour_text} #{minute_text}"
  end
end
