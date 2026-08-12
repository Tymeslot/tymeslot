defmodule TymeslotWeb.Dashboard.CalendarGrid.Views.EventBadges do
  @moduledoc "Guest RSVP and seat-lock badge helpers shared by the calendar grid views."

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  # ---------- Seat lock indicator ----------

  @doc """
  Whether a live seat is held on the meeting behind this event.

  Such an event's time belongs to the booking, not to the calendar: dragging
  the provider event would leave every participant booked at the old time.
  The grid marks these locked and refuses the move server-side.
  """
  @spec seat_locked?(MapSet.t() | nil, map()) :: boolean()
  def seat_locked?(nil, _event), do: false
  def seat_locked?(uids, event), do: MapSet.member?(uids, Map.get(event, :uid))

  attr :locked, :boolean, default: false

  @spec seat_lock_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def seat_lock_badge(assigns) do
    ~H"""
    <span
      :if={@locked}
      class="absolute bottom-0.5 right-0.5 inline-flex items-center rounded-full bg-black/25 p-px"
      title={seat_lock_title()}
    >
      <.icon name="hero-lock-closed-micro" class="w-2.5 h-2.5" />
    </span>
    """
  end

  @doc "The tooltip explaining why a seat-locked event cannot be moved."
  @spec seat_lock_title() :: String.t()
  def seat_lock_title do
    dgettext(
      "dashboard_calendar",
      "Several people are booked on this slot, so its time is fixed here. Open the booking and ask them to rebook to move it."
    )
  end

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
      dgettext("dashboard_calendar", "%{accepted} of %{total} guests going",
        accepted: accepted,
        total: total
      )

    if declined > 0 do
      declined_fragment =
        dngettext("dashboard_calendar", ", %{count} declined", ", %{count} declined", declined,
          count: declined
        )

      base <> declined_fragment
    else
      base
    end
  end
end
