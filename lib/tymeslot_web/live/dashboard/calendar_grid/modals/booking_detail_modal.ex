defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.BookingDetailModal do
  @moduledoc """
  Read-only detail modal for a Tymeslot booking shown on the calendar grid.

  Bookings are managed through the booking flows (cancel with refund handling,
  reschedule requests) rather than edited like provider events, so this modal
  presents the booking and links to the Meetings page for those actions.

  A group booking also shows how many of its seats are taken and, beside the
  link, why it cannot be moved or deleted from the calendar: the same
  wording the grid's lock badge and its refusals use.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers
  alias TymeslotWeb.Helpers.LocaleFormat

  attr :booking, :map, required: true
  attr :user_timezone, :string, required: true
  attr :time_format, :any, default: nil
  attr :myself, :any, required: true

  @spec booking_detail_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def booking_detail_modal(assigns) do
    ~H"""
    <.modal
      id="booking-detail-modal"
      show={true}
      on_cancel={JS.push("close_booking_detail", target: @myself)}
      size={:medium}
    >
      <:header>
        <div class="flex items-center gap-2 min-w-0">
          <img src="/images/brand/logo.svg" alt="" class="w-5 h-5 shrink-0" />
          <span class="truncate">{@booking.summary}</span>
        </div>
      </:header>

      <div class="space-y-4" data-testid="booking-detail">
        <div class="flex items-start gap-3">
          <.icon name="hero-clock" class="w-5 h-5 text-tymeslot-400 shrink-0 mt-0.5" />
          <div>
            <div class="text-token-sm font-medium text-tymeslot-800">
              {booking_date_label(@booking, @user_timezone)}
            </div>
            <div class="text-token-sm text-tymeslot-500">
              {Helpers.format_display_time_range(@booking, @time_format, @user_timezone)}
            </div>
          </div>
        </div>

        <div
          :if={@booking.participants != []}
          class="flex items-start gap-3"
          data-testid="booking-participants"
        >
          <.icon name="hero-user-group" class="w-5 h-5 text-tymeslot-400 shrink-0 mt-0.5" />
          <div class="min-w-0 space-y-2">
            <p
              :if={group?(@booking)}
              class="text-token-xs font-semibold uppercase tracking-wider text-turquoise-700"
              data-testid="booking-seats"
            >
              {dgettext("dashboard_calendar", "%{count}/%{capacity} seats taken",
                count: @booking.seats_taken,
                capacity: @booking.capacity
              )}
            </p>
            <ul class="min-w-0 space-y-2">
              <li :for={participant <- @booking.participants} class="min-w-0">
                <div :if={participant.name} class="text-token-sm font-medium text-tymeslot-800">
                  {participant.name}
                </div>
                <div class="text-token-sm text-tymeslot-500 truncate">{participant.email}</div>
              </li>
            </ul>
          </div>
        </div>

        <div :if={@booking.attendee_name || @booking.attendee_email} class="flex items-start gap-3">
          <.icon name="hero-user" class="w-5 h-5 text-tymeslot-400 shrink-0 mt-0.5" />
          <div class="min-w-0">
            <div :if={@booking.attendee_name} class="text-token-sm font-medium text-tymeslot-800">
              {@booking.attendee_name}
            </div>
            <div :if={@booking.attendee_email} class="text-token-sm text-tymeslot-500 truncate">
              {@booking.attendee_email}
            </div>
          </div>
        </div>

        <div :if={@booking.location} class="flex items-start gap-3">
          <.icon name="hero-map-pin" class="w-5 h-5 text-tymeslot-400 shrink-0 mt-0.5" />
          <div class="text-token-sm text-tymeslot-700 break-words min-w-0">
            {@booking.location}
          </div>
        </div>

        <div class="flex items-center gap-2 text-token-xs text-tymeslot-500">
          <.icon name="hero-check-badge" class="w-4 h-4 text-turquoise-500" />
          {dgettext("dashboard_calendar", "Booked through your Tymeslot page")}
        </div>
      </div>

      <:footer>
        <div class="flex flex-wrap items-center justify-end gap-x-4 gap-y-2">
          <p
            :if={group?(@booking)}
            class="flex items-start gap-1.5 text-token-xs text-tymeslot-500 min-w-0 flex-1 basis-56"
            data-testid="booking-lock-note"
          >
            <.icon name="hero-lock-closed-micro" class="w-3.5 h-3.5 shrink-0 mt-px" />
            <span>{Shared.seat_lock_message()}</span>
          </p>
          <div class="flex flex-wrap gap-2">
            <a
              :if={@booking.join_url}
              href={@booking.join_url}
              target="_blank"
              rel="noopener noreferrer"
              class="inline-flex items-center gap-2 px-4 py-2 bg-turquoise-600 hover:bg-turquoise-700 text-white text-token-sm font-semibold rounded-token-lg transition-colors"
            >
              <.icon name="hero-video-camera" class="w-4 h-4" />
              {dgettext("dashboard_calendar", "Join meeting")}
            </a>
            <.link
              patch={~p"/dashboard/meetings"}
              class="inline-flex items-center gap-2 px-4 py-2 bg-tymeslot-50 hover:bg-tymeslot-100 text-tymeslot-700 text-token-sm font-semibold rounded-token-lg transition-colors"
            >
              <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" />
              {dgettext("dashboard_calendar", "Manage in Meetings")}
            </.link>
          </div>
        </div>
      </:footer>
    </.modal>
    """
  end

  defp group?(%{participants: [_first | _rest], capacity: capacity}) when capacity > 1,
    do: true

  defp group?(_booking), do: false

  defp booking_date_label(booking, timezone) do
    booking
    |> Helpers.event_display_date(timezone)
    |> LocaleFormat.format_weekday_date(Gettext.get_locale(TymeslotWeb.Gettext))
  end
end
