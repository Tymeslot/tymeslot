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
  clause and rendered "Scheduled". `badge_variant/1` below names every status
  in `Tymeslot.Meetings.MeetingSchema`'s valid list either its own explicit
  clause or the time-derived split (scheduled vs completed, the only pair
  that genuinely depends on the clock rather than the status column). Only a
  status this module has never heard of falls through the final `true` case.
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
           | :awaiting_payment
           | :completed
           | :scheduled

  attr :meeting, :map, required: true

  @spec status_badges(map()) :: Phoenix.LiveView.Rendered.t()
  def status_badges(assigns) do
    variant = badge_variant(assigns.meeting)

    assigns =
      assign(assigns,
        tone: badge_tone(variant),
        icon: badge_icon(variant),
        label: badge_label(variant)
      )

    ~H"""
    <CoreComponents.pill tone={@tone} size={:sm} icon={@icon}>
      {@label}
    </CoreComponents.pill>
    """
  end

  # Cancelled, expired, awaiting payment and completed are read straight off
  # `status`: all four are terminal or Stripe-driven and none is contingent
  # on the meeting's time — an unpaid checkout badged "Scheduled" is the
  # "unconfirmed thing shown as agreed" failure this feature exists to
  # remove, one status over. Everything else derives from the
  # live/awaiting/past shape, in priority order; "pending" and "confirmed"
  # both fall to the time-derived split deliberately, since neither implies
  # anything beyond it.
  @spec badge_variant(map()) :: variant()
  defp badge_variant(%{status: "cancelled"}), do: :cancelled
  defp badge_variant(%{status: "expired"}), do: :expired
  defp badge_variant(%{status: "awaiting_payment"}), do: :awaiting_payment
  defp badge_variant(%{status: "completed"}), do: :completed

  defp badge_variant(meeting) do
    cond do
      MeetingState.awaiting_new_time?(meeting) -> :awaiting_new_time
      MeetingState.awaiting_approval?(meeting) -> :awaiting_approval
      Helpers.past_meeting?(meeting) -> :completed
      true -> :scheduled
    end
  end

  @spec badge_tone(variant()) :: atom()
  defp badge_tone(:cancelled), do: :danger
  defp badge_tone(:expired), do: :neutral
  defp badge_tone(:awaiting_new_time), do: :warning
  defp badge_tone(:awaiting_approval), do: :warning
  defp badge_tone(:awaiting_payment), do: :warning
  defp badge_tone(:completed), do: :neutral
  defp badge_tone(:scheduled), do: :success

  @spec badge_icon(variant()) :: String.t()
  defp badge_icon(:cancelled), do: "hero-x-mark"
  defp badge_icon(:expired), do: "hero-clock"
  defp badge_icon(:awaiting_new_time), do: "hero-clock"
  defp badge_icon(:awaiting_approval), do: "hero-inbox-arrow-down"
  defp badge_icon(:awaiting_payment), do: "hero-credit-card"
  defp badge_icon(:completed), do: "hero-check"
  defp badge_icon(:scheduled), do: "hero-calendar-days"

  @spec badge_label(variant()) :: String.t()
  defp badge_label(:cancelled), do: dgettext("dashboard_bookings", "Cancelled")
  defp badge_label(:expired), do: dgettext("dashboard_bookings", "Expired")
  defp badge_label(:awaiting_new_time), do: dgettext("dashboard_bookings", "Reschedule Requested")

  defp badge_label(:awaiting_approval),
    do: dgettext("dashboard_bookings", "Awaiting your approval")

  defp badge_label(:awaiting_payment),
    do: dgettext("dashboard_bookings", "Awaiting payment")

  defp badge_label(:completed), do: dgettext("dashboard_bookings", "Completed")
  defp badge_label(:scheduled), do: dgettext("dashboard_bookings", "Scheduled")
end
