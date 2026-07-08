defmodule TymeslotWeb.Dashboard.CalendarGrid.Helpers.TimeFormatting do
  @moduledoc "Date/time formatting utilities for the calendar grid: time ranges, timezone abbreviations, and local date parts."

  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.HTML

  @spec format_time_range(map(), String.t()) :: String.t()
  def format_time_range(event, fmt \\ "12h") do
    if event.all_day do
      dgettext("dashboard_calendar", "All day")
    else
      start_str = format_datetime(event.start_at, fmt)
      end_str = format_datetime(event.end_at, fmt)
      "#{start_str} \u2013 #{end_str}"
    end
  end

  @doc """
  Formats the time range using the original (unclamped) times when available.
  Multi-day events include a short date (e.g. "10:30 Apr 1 – 11:00 Apr 2")
  so the label isn't misleading about duration.
  """
  @spec format_display_time_range(map(), String.t(), String.t()) :: String.t()
  def format_display_time_range(event, fmt \\ "12h", timezone \\ "Etc/UTC") do
    start_at = Map.get(event, :display_start_at, event.start_at)
    end_at = Map.get(event, :display_end_at, event.end_at)

    if event.all_day do
      dgettext("dashboard_calendar", "All day")
    else
      start_local = DateTime.shift_zone!(start_at, timezone)
      end_local = DateTime.shift_zone!(end_at, timezone)
      start_date = DateTime.to_date(start_local)
      end_date = DateTime.to_date(end_local)

      if Date.compare(start_date, end_date) == :eq do
        start_str = format_datetime(start_local, fmt)
        end_str = format_datetime(end_local, fmt)
        "#{start_str} \u2013 #{end_str}"
      else
        start_str = format_datetime_with_date(start_local, fmt)
        end_str = format_datetime_with_date(end_local, fmt)
        "#{start_str} \u2013 #{end_str}"
      end
    end
  end

  @spec format_time_range_in_tz(map(), String.t(), String.t()) :: String.t()
  def format_time_range_in_tz(event, timezone, fmt \\ "12h") do
    if event.all_day do
      dgettext("dashboard_calendar", "All day")
    else
      start_local = DateTime.shift_zone!(event.start_at, timezone)
      end_local = DateTime.shift_zone!(event.end_at, timezone)
      start_str = format_datetime(start_local, fmt)
      end_str = format_datetime(end_local, fmt)
      "#{start_str} \u2013 #{end_str}"
    end
  end

  @spec tz_abbr(String.t()) :: String.t()
  def tz_abbr(timezone) do
    case DateTime.now(timezone) do
      {:ok, dt} -> Calendar.strftime(dt, "%Z")
      _error -> timezone
    end
  end

  @spec datetime_to_local_parts(DateTime.t() | nil, String.t()) ::
          %{date: String.t(), time: String.t()}
  def datetime_to_local_parts(nil, _timezone), do: %{date: "", time: ""}

  def datetime_to_local_parts(dt, timezone) do
    local = DateTime.shift_zone!(dt, timezone)
    date = Date.to_iso8601(DateTime.to_date(local))
    time = Calendar.strftime(local, "%H:%M")
    %{date: date, time: time}
  end

  @spec format_hour(integer(), map()) :: String.t()
  def format_hour(hour, assigns) do
    if time_format(assigns) == "24h" do
      String.pad_leading(Integer.to_string(hour), 2, "0") <> ":00"
    else
      Calendar.strftime(Time.new!(hour, 0, 0), "%I %p")
    end
  end

  @spec user_timezone(map()) :: String.t()
  def user_timezone(assigns), do: assigns.user_timezone

  @spec user_tz_abbr(map()) :: String.t()
  def user_tz_abbr(assigns) do
    tz = assigns.user_timezone

    case DateTime.now(tz) do
      {:ok, dt} -> Calendar.strftime(dt, "%Z")
      _error -> tz
    end
  end

  @spec url?(String.t()) :: boolean()
  def url?(str), do: String.match?(str, ~r{^https?://})

  @url_regex ~r{https?://[^\s<>"]+}

  @spec linkify_text(String.t()) :: HTML.safe()
  def linkify_text(text) do
    html =
      @url_regex
      |> Regex.split(text, include_captures: true)
      |> Enum.map_join(fn part ->
        if Regex.match?(~r{^https?://}, part) do
          display = part |> HTML.html_escape() |> HTML.safe_to_string()
          href = part |> HTML.html_escape() |> HTML.safe_to_string()

          ~s(<a href="#{href}" target="_blank" rel="noopener noreferrer" ) <>
            ~s(class="text-turquoise-600 underline break-all hover:text-turquoise-800">#{display}</a>)
        else
          part |> HTML.html_escape() |> HTML.safe_to_string()
        end
      end)

    HTML.raw(html)
  end

  # Private helpers

  defp format_datetime(dt, "24h"), do: Calendar.strftime(dt, "%H:%M")
  defp format_datetime(dt, _fmt), do: Calendar.strftime(dt, "%-I:%M %p")

  defp format_datetime_with_date(dt, "24h"), do: Calendar.strftime(dt, "%H:%M %b %-d")
  defp format_datetime_with_date(dt, _fmt), do: Calendar.strftime(dt, "%-I:%M %p %b %-d")

  defp time_format(%{preferences: %{time_format: fmt}}), do: fmt
  defp time_format(_assigns), do: "12h"
end
