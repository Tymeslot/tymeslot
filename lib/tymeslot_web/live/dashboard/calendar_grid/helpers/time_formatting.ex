defmodule TymeslotWeb.Dashboard.CalendarGrid.Helpers.TimeFormatting do
  @moduledoc "Date/time formatting utilities for the calendar grid: time ranges, timezone abbreviations, and local date parts."

  alias Phoenix.HTML
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers.PreferenceHelpers
  alias TymeslotWeb.Dashboard.DashboardFormat

  @doc """
  An event's time range in the organiser's timezone and clock, from its
  original times when the grid has clamped it to one day, so the label is not
  misleading about duration. See `DashboardFormat.time_range/4`, which names
  both days of a range crossing midnight.
  """
  @spec format_display_time_range(map(), String.t(), String.t()) :: String.t()
  def format_display_time_range(%{all_day: true}, _fmt, _timezone), do: DashboardFormat.all_day()

  def format_display_time_range(event, fmt, timezone) do
    start_at = Map.get(event, :display_start_at, event.start_at)
    end_at = Map.get(event, :display_end_at, event.end_at)
    DashboardFormat.time_range(start_at, end_at, timezone, fmt)
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

  defdelegate time_format(assigns), to: PreferenceHelpers
end
