defmodule TymeslotWeb.Components.Dashboard.Meetings.MeetingStatusBadge do
  @moduledoc """
  The one badge that says what state a booking is in.

  Split out of `MeetingListComponents` when the approval gate added a fifth
  state, because the branches are mutually exclusive and each one has to
  exclude every other: a held request that also matches "not cancelled and not
  past" would render as both "Awaiting your approval" and "Scheduled", which is
  precisely the contradiction this feature exists to remove.

  Kept as sibling `:if` clauses rather than a `cond`, matching the surrounding
  file, but the exclusions are the load-bearing part — do not add a state
  without adding it to the guards below it.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Meetings.MeetingState
  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Components.Dashboard.Meetings.Helpers

  attr :meeting, :map, required: true

  @spec status_badges(map()) :: Phoenix.LiveView.Rendered.t()
  def status_badges(assigns) do
    ~H"""
    <span
      :if={@meeting.status == "cancelled"}
      class="inline-flex items-center gap-1.5 px-3 py-1 bg-red-50 text-red-700 text-token-xs font-black uppercase tracking-wider rounded-full border border-red-100 shadow-sm"
    >
      <CoreComponents.icon name="hero-x-mark" class="w-3 h-3" /> {dgettext(
        "dashboard_bookings",
        "Cancelled"
      )}
    </span>
    <span
      :if={@meeting.status != "cancelled" and MeetingState.awaiting_new_time?(@meeting)}
      class="inline-flex items-center gap-1.5 px-3 py-1 bg-amber-50 text-amber-700 text-token-xs font-black uppercase tracking-wider rounded-full border border-amber-100 shadow-sm"
    >
      <CoreComponents.icon name="hero-clock" class="w-3 h-3" /> {dgettext(
        "dashboard_bookings",
        "Reschedule Requested"
      )}
    </span>
    <span
      :if={MeetingState.awaiting_approval?(@meeting)}
      class="inline-flex items-center gap-1.5 px-3 py-1 bg-amber-50 text-amber-700 text-token-xs font-black uppercase tracking-wider rounded-full border border-amber-100 shadow-sm"
    >
      <CoreComponents.icon name="hero-inbox-arrow-down" class="w-3 h-3" /> {dgettext(
        "dashboard_bookings",
        "Awaiting your approval"
      )}
    </span>
    <span
      :if={
        @meeting.status != "cancelled" and !MeetingState.awaiting_new_time?(@meeting) and
          !MeetingState.awaiting_approval?(@meeting) and
          Helpers.past_meeting?(@meeting)
      }
      class="inline-flex items-center gap-1.5 px-3 py-1 bg-tymeslot-100 text-tymeslot-600 text-token-xs font-black uppercase tracking-wider rounded-full border border-tymeslot-200 shadow-sm"
    >
      <CoreComponents.icon name="hero-check" class="w-3 h-3" /> {dgettext(
        "dashboard_bookings",
        "Completed"
      )}
    </span>
    <span
      :if={
        @meeting.status != "cancelled" and !MeetingState.awaiting_new_time?(@meeting) and
          !MeetingState.awaiting_approval?(@meeting) and
          !Helpers.past_meeting?(@meeting)
      }
      class="inline-flex items-center gap-1.5 px-3 py-1 bg-emerald-50 text-emerald-700 text-token-xs font-black uppercase tracking-wider rounded-full border border-emerald-100 shadow-sm"
    >
      <CoreComponents.icon name="hero-calendar-days" class="w-3 h-3" /> {dgettext(
        "dashboard_bookings",
        "Scheduled"
      )}
    </span>
    """
  end
end
