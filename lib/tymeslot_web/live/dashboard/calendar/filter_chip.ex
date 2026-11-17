defmodule TymeslotWeb.Dashboard.Calendar.FilterChip do
  @moduledoc """
  The toolbar's filter chip: filters never hide silently. Without a
  calendar set it shows how many calendars are hidden whenever the rail is
  not showing them (collapsed, or always below 768px), and its × shows them
  all. While a set is active it names the set, with the count when the set
  hides any, whether the rail is open or not, and its × leaves the set.
  Both go through `calendar:show_all` (see `Visibility.show_all/1`).
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  attr :hidden_count, :integer, required: true
  attr :set_name, :string, default: nil
  attr :rail_open, :boolean, required: true
  attr :target, :any, required: true

  @spec filter_chip(map()) :: Phoenix.LiveView.Rendered.t()
  def filter_chip(assigns) do
    ~H"""
    <div
      :if={@hidden_count > 0 or not is_nil(@set_name)}
      id="calendar-filter-chip"
      class={[
        "inline-flex min-w-0 items-center gap-1 rounded-token-full border border-amber-300 bg-amber-50 py-0.5 pl-3 pr-1 text-token-xs font-semibold text-amber-900",
        if(@rail_open and is_nil(@set_name), do: "md:hidden")
      ]}
    >
      <span class="truncate">{label(@set_name, @hidden_count)}</span>
      <button
        type="button"
        id="calendar-show-all"
        phx-click="calendar:show_all"
        phx-target={@target}
        aria-label={close_label(@set_name)}
        class="inline-flex h-6 w-6 shrink-0 items-center justify-center rounded-token-full hover:bg-amber-100 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-amber-500"
      >
        <.icon name="hero-x-mark-mini" class="h-4 w-4" />
      </button>
    </div>
    """
  end

  defp label(nil, count),
    do:
      dngettext(
        "dashboard_calendar",
        "%{count} calendar hidden",
        "%{count} calendars hidden",
        count
      )

  defp label(name, 0), do: dgettext("dashboard_calendar_power", "%{name} set", name: name)

  defp label(name, count),
    do:
      dngettext(
        "dashboard_calendar_power",
        "%{name} set · %{count} calendar hidden",
        "%{name} set · %{count} calendars hidden",
        count,
        name: name
      )

  defp close_label(nil), do: dgettext("dashboard_calendar", "Show all calendars")

  defp close_label(name),
    do: dgettext("dashboard_calendar_power", "Leave the %{name} set", name: name)
end
