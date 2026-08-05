defmodule TymeslotWeb.Dashboard.DashboardOverviewFormatters do
  @moduledoc """
  Pure date/time and countdown label formatting for the dashboard overview
  agenda. Extracted from `DashboardOverviewComponent` to keep that component
  focused on presentation and state.
  """
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Agenda.Entry
  alias Tymeslot.Utils.DateTimeUtils
  alias Tymeslot.Utils.DateTimeUtils.TimeFormat
  alias TymeslotWeb.Helpers.LocaleFormat

  # Server-rendered starting text for the cockpit countdown; the AgendaCountdown
  # JS hook replaces it live on mount and ticks it thereafter.
  @spec relative_hint(Entry.t()) :: String.t()
  def relative_hint(entry) do
    diff = DateTime.diff(entry.start_at, DateTime.utc_now(), :second)

    cond do
      diff <= 0 -> dgettext("dashboard_home", "now")
      diff < 3600 -> dgettext("dashboard_home", "in %{minutes}m", minutes: div(diff, 60))
      diff < 86_400 -> dgettext("dashboard_home", "in %{hours}h", hours: div(diff, 3600))
      true -> dgettext("dashboard_home", "in %{days}d", days: div(diff, 86_400))
    end
  end

  @spec day_label(Entry.t(), String.t()) :: String.t()
  def day_label(entry, timezone) do
    today = local_date(DateTime.utc_now(), timezone)

    cond do
      Entry.covers?(entry, today, timezone) -> dgettext("dashboard_home", "Today")
      Entry.covers?(entry, Date.add(today, 1), timezone) -> dgettext("dashboard_home", "Tomorrow")
      true -> short_date_label(entry.day)
    end
  end

  defp short_date_label(day) do
    locale = Gettext.get_locale(TymeslotWeb.Gettext)
    weekday = LocaleFormat.format_weekday_name(Date.day_of_week(day), locale, :short)
    month = LocaleFormat.format_month_name(day.month, locale, :short)
    "#{weekday} #{day.day} #{month}"
  end

  @spec time_label(Entry.t(), String.t(), String.t()) :: String.t()
  def time_label(%{all_day?: true}, _timezone, _time_format),
    do: dgettext("dashboard_home", "All day")

  def time_label(entry, timezone, time_format) do
    now_time_label(entry.start_at, timezone, time_format)
  end

  @doc """
  Formats a UTC datetime as a clock label in the given timezone, using the
  organiser's resolved clock format. The agenda is theirs, so the format is
  taken explicitly rather than inferred, and every label on the page agrees.
  """
  @spec now_time_label(DateTime.t(), String.t(), String.t()) :: String.t()
  def now_time_label(datetime, timezone, time_format) do
    datetime
    |> DateTimeUtils.convert_to_timezone(timezone)
    |> TimeFormat.format(time_format)
  end

  @spec local_date(DateTime.t(), String.t()) :: Date.t()
  def local_date(datetime, timezone),
    do: datetime |> DateTimeUtils.convert_to_timezone(timezone) |> DateTime.to_date()
end
