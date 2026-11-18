defmodule TymeslotWeb.Dashboard.Calendar.PreviewGuests do
  @moduledoc """
  The preview's guests row: how many of those invited are going, when any
  has answered, then the first five people with each one's answer
  (`GuestStatusPill`), then how many more there are. The answers come from
  `Tymeslot.CalendarGrid.GuestReplies`; someone with no answer to show (who
  booked, or whose calendar reported none) shows their name alone. The same
  rows serve the phone's bottom sheet; a long name truncates.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CalendarGrid.GuestReplies
  alias TymeslotWeb.Components.Dashboard.Meetings.GuestStatusPill

  @limit 5

  attr :guests, :list, required: true, doc: "`GuestReplies.of_event/1`"

  @spec guests(map()) :: Phoenix.LiveView.Rendered.t()
  def guests(assigns) do
    {shown, rest} = Enum.split(assigns.guests, @limit)

    assigns =
      assign(assigns,
        shown: shown,
        rest: length(rest),
        summary: GuestReplies.summary(assigns.guests)
      )

    ~H"""
    <div id="calendar-preview-guests" class="flex items-start gap-2">
      <.icon name="hero-user-group" class="mt-0.5 h-4 w-4 shrink-0 text-tymeslot-400" />
      <div class="min-w-0 flex-1 space-y-1">
        <p :if={@summary} id="calendar-preview-guest-summary" class="text-tymeslot-500">
          {GuestReplies.summary_text(@summary)}
        </p>
        <ul class="space-y-1">
          <li :for={guest <- @shown} class="flex min-w-0 items-center gap-2">
            <span class="min-w-0 truncate">{guest.name}</span>
            <GuestStatusPill.guest_status_pill :if={guest.reply} status={guest.reply} />
          </li>
        </ul>
        <p :if={@rest > 0} class="text-tymeslot-500">
          {dngettext("dashboard_calendar_power", "%{count} more guest", "%{count} more guests", @rest)}
        </p>
      </div>
    </div>
    """
  end
end
