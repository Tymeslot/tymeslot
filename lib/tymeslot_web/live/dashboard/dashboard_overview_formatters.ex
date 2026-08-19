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

  # Stand-in substituted for the live value inside a translated template
  # handed to the AgendaCountdown JS hook; see `countdown_templates/0`.
  @placeholder "__N__"

  # Server-rendered starting text for the cockpit countdown; the AgendaCountdown
  # JS hook re-ticks it client-side thereafter, filling `countdown_templates/0`
  # rather than composing its own English strings.
  @spec relative_hint(Entry.t()) :: String.t()
  def relative_hint(entry) do
    diff = DateTime.diff(entry.start_at, DateTime.utc_now(), :second)

    if diff <= 0, do: dgettext("dashboard_home", "now"), else: countdown(diff)
  end

  @doc """
  The countdown text for an entry `seconds` away.

  Shared with `AgendaDetailModal`, which renders the same entry: the two used
  to carry the same gettext msgid and disagree below a minute, one showing
  "in 0m" where the other clamped to "in 1m". A countdown that reads zero is
  the wrong one.
  """
  @spec countdown(integer()) :: String.t()
  def countdown(seconds) when seconds < 3600,
    do: fill(minutes_template(), max(div(seconds, 60), 1))

  def countdown(seconds) when seconds < 86_400,
    do: fill(hours_template(), div(seconds, 3600))

  def countdown(seconds),
    do: fill(days_template(), div(seconds, 86_400))

  @doc """
  Translated countdown templates for the `AgendaCountdown` JS hook, one per
  band plus the "now" state, each still carrying `#{@placeholder}` where the
  live value belongs. The hook fills the placeholder as it ticks so the band
  boundaries and their wording live in exactly one place: here.
  """
  @spec countdown_templates() :: %{
          now: String.t(),
          minutes: String.t(),
          hours: String.t(),
          days: String.t()
        }
  def countdown_templates do
    %{
      now: dgettext("dashboard_home", "now"),
      minutes: minutes_template(),
      hours: hours_template(),
      days: days_template()
    }
  end

  defp minutes_template, do: dgettext("dashboard_home", "in %{minutes}m", minutes: @placeholder)
  defp hours_template, do: dgettext("dashboard_home", "in %{hours}h", hours: @placeholder)
  defp days_template, do: dgettext("dashboard_home", "in %{days}d", days: @placeholder)

  defp fill(template, value), do: String.replace(template, @placeholder, Integer.to_string(value))

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
