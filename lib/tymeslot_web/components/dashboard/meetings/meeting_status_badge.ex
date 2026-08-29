defmodule TymeslotWeb.Components.Dashboard.Meetings.MeetingStatusBadge do
  @moduledoc """
  The one badge that says what state a booking is in.

  Split out of `MeetingListComponents` when the approval gate added a fifth
  state, because the states are mutually exclusive: a held request that also
  matches "not cancelled and not past" must not render as both "Awaiting your
  approval" and "Scheduled", which is precisely the contradiction this feature
  exists to remove.

  Used to be sibling `:if` clauses, each repeating every other state's
  negation as a guard. That shape silently swallowed `"expired"`: it matched
  none of the guards, so it fell through to the last (unguarded-by-status)
  clause and rendered "Scheduled". `badge_variant/1` below is a total mapping
  instead — every status gets an explicit outcome, and a status nobody has
  named a clause for is a compile-time dialyzer gap rather than a wrong badge
  in production.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Meetings.MeetingState
  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Components.Dashboard.Meetings.Helpers

  @typep variant ::
           :cancelled
           | :expired
           | :awaiting_new_time
           | :awaiting_approval
           | :completed
           | :scheduled

  @base_classes "inline-flex items-center gap-1.5 px-3 py-1 text-token-xs font-black uppercase tracking-wider rounded-full border shadow-sm"

  attr :meeting, :map, required: true

  @spec status_badges(map()) :: Phoenix.LiveView.Rendered.t()
  def status_badges(assigns) do
    variant = badge_variant(assigns.meeting)

    assigns =
      assign(assigns,
        classes: badge_classes(variant),
        icon: badge_icon(variant),
        label: badge_label(variant)
      )

    ~H"""
    <span class={@classes}>
      <CoreComponents.icon name={@icon} class="w-3 h-3" /> {@label}
    </span>
    """
  end

  # Cancelled and expired are read straight off `status`: both are terminal
  # and neither is contingent on the meeting's time. Everything else derives
  # from the live/awaiting/past shape, in priority order.
  @spec badge_variant(map()) :: variant()
  defp badge_variant(%{status: "cancelled"}), do: :cancelled
  defp badge_variant(%{status: "expired"}), do: :expired

  defp badge_variant(meeting) do
    cond do
      MeetingState.awaiting_new_time?(meeting) -> :awaiting_new_time
      MeetingState.awaiting_approval?(meeting) -> :awaiting_approval
      Helpers.past_meeting?(meeting) -> :completed
      true -> :scheduled
    end
  end

  @spec badge_classes(variant()) :: String.t()
  defp badge_classes(:cancelled), do: @base_classes <> " bg-red-50 text-red-700 border-red-100"

  defp badge_classes(:expired),
    do: @base_classes <> " bg-tymeslot-100 text-tymeslot-500 border-tymeslot-200"

  defp badge_classes(:awaiting_new_time),
    do: @base_classes <> " bg-amber-50 text-amber-700 border-amber-100"

  defp badge_classes(:awaiting_approval),
    do: @base_classes <> " bg-amber-50 text-amber-700 border-amber-100"

  defp badge_classes(:completed),
    do: @base_classes <> " bg-tymeslot-100 text-tymeslot-600 border-tymeslot-200"

  defp badge_classes(:scheduled),
    do: @base_classes <> " bg-emerald-50 text-emerald-700 border-emerald-100"

  @spec badge_icon(variant()) :: String.t()
  defp badge_icon(:cancelled), do: "hero-x-mark"
  defp badge_icon(:expired), do: "hero-clock"
  defp badge_icon(:awaiting_new_time), do: "hero-clock"
  defp badge_icon(:awaiting_approval), do: "hero-inbox-arrow-down"
  defp badge_icon(:completed), do: "hero-check"
  defp badge_icon(:scheduled), do: "hero-calendar-days"

  @spec badge_label(variant()) :: String.t()
  defp badge_label(:cancelled), do: dgettext("dashboard_bookings", "Cancelled")
  defp badge_label(:expired), do: dgettext("dashboard_bookings", "Expired")
  defp badge_label(:awaiting_new_time), do: dgettext("dashboard_bookings", "Reschedule Requested")

  defp badge_label(:awaiting_approval),
    do: dgettext("dashboard_bookings", "Awaiting your approval")

  defp badge_label(:completed), do: dgettext("dashboard_bookings", "Completed")
  defp badge_label(:scheduled), do: dgettext("dashboard_bookings", "Scheduled")
end
