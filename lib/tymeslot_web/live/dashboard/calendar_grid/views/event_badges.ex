defmodule TymeslotWeb.Dashboard.CalendarGrid.Views.EventBadges do
  @moduledoc "Guest RSVP badge/indicator helpers shared by the calendar grid views."

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  # ---------- Guest RSVP indicator ----------

  # Compact accepted/total pill shown on Tymeslot-created timed event blocks.
  attr :summary, :map, default: nil

  @spec event_guest_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def event_guest_badge(assigns) do
    ~H"""
    <span
      :if={@summary}
      class={[
        "absolute bottom-0.5 left-0.5 inline-flex items-center gap-0.5 rounded-full px-1 py-px text-token-2xs font-bold leading-none",
        guest_badge_tone(@summary)
      ]}
      title={guest_badge_title(@summary)}
    >
      <.icon name="hero-user-mini" class="w-2.5 h-2.5" />
      {@summary.accepted}/{@summary.total}
    </span>
    """
  end

  # Returns the RSVP summary for a Tymeslot-created event, or nil.
  @spec guest_summary_for_event(map() | nil, map()) :: map() | nil
  def guest_summary_for_event(summaries, event) do
    if Map.get(event, :created_by_tymeslot) do
      Map.get(summaries || %{}, Map.get(event, :uid))
    end
  end

  defp guest_badge_tone(%{declined: declined}) when declined > 0, do: "bg-red-500/90 text-white"

  defp guest_badge_tone(%{total: total, accepted: accepted}) when total > 0 and accepted == total,
    do: "bg-green-600/90 text-white"

  defp guest_badge_tone(_summary), do: "bg-amber-500/90 text-white"

  @spec guest_dot_tone(map()) :: String.t()
  def guest_dot_tone(%{declined: declined}) when declined > 0, do: "bg-red-500"

  def guest_dot_tone(%{total: total, accepted: accepted}) when total > 0 and accepted == total,
    do: "bg-green-500"

  def guest_dot_tone(_summary), do: "bg-amber-500"

  @spec guest_badge_title(map()) :: String.t()
  def guest_badge_title(%{accepted: accepted, total: total, declined: declined}) do
    base =
      dgettext("dashboard", "%{accepted} of %{total} guests going",
        accepted: accepted,
        total: total
      )

    if declined > 0 do
      declined_fragment =
        dngettext("dashboard", ", %{count} declined", ", %{count} declined", declined,
          count: declined
        )

      base <> declined_fragment
    else
      base
    end
  end
end
