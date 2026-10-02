defmodule TymeslotWeb.Dashboard.DashboardOverviewFormatters do
  @moduledoc """
  The live countdown wording for the dashboard agenda ("in 40m"), shared by
  the server render and the `AgendaCountdown` JS hook. Dates, clocks and
  durations are `TymeslotWeb.Dashboard.DashboardFormat`'s.
  """
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Agenda.Entry

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
end
