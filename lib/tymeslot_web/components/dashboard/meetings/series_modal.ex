defmodule TymeslotWeb.Components.Dashboard.Meetings.SeriesModal do
  @moduledoc """
  A booked series as its host sees it, opened by "View series" on any of its
  sessions' cards: who booked it, the meeting type and its rhythm in words,
  what was paid and refunded for a paid series, and every session with its
  date, time, status and the actions a session allows on its own.

  A session's own actions close this modal and open theirs (the cancel or
  reschedule dialog the session's card opens), as does "Cancel remaining
  sessions": two dialogs open at once would each close on a click in the
  other.

  Shown for a one-to-one series only. On a group type every session is a
  shared meeting and the series is one booker's seats in them, so a session's
  card has no series of its own to show.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.BookingSeries
  alias Tymeslot.Utils.DateTimeUtils
  alias TymeslotWeb.Components.CoreComponents.Buttons
  alias TymeslotWeb.Components.CoreComponents.Containers
  alias TymeslotWeb.Components.CoreComponents.Modal
  alias TymeslotWeb.Components.Dashboard.Meetings.Helpers
  alias TymeslotWeb.Components.Dashboard.Meetings.MeetingStatusBadge

  import TymeslotWeb.Components.PaymentHelpers, only: [format_amount: 2]

  attr :id, :string, required: true
  attr :show, :boolean, required: true
  attr :overview, :map, default: nil, doc: "`Tymeslot.BookingSeries.organizer_overview/1`"
  attr :timezone, :string, required: true
  attr :time_format, :string, required: true
  attr :target, :any, required: true

  @spec series_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def series_modal(assigns) do
    ~H"""
    <Modal.modal
      id={@id}
      show={@show}
      size={:large}
      on_cancel={JS.push("series:hide", target: @target)}
    >
      <:header>
        {if @overview,
          do:
            dgettext("dashboard_booking_series", "Series with %{name}",
              name: @overview.series.attendee_name
            )}
      </:header>
      <:subtitle :if={@overview}>{type_name(@overview.series)}</:subtitle>

      <div :if={@overview} class="space-y-6" data-testid="series-modal">
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <Containers.detail_line
            variant={:tile}
            icon="hero-user"
            label={dgettext("dashboard_booking_series", "Booked by")}
          >
            {@overview.series.attendee_name}
            <a
              href={"mailto:#{@overview.series.attendee_email}"}
              class="block truncate text-turquoise-600 hover:text-turquoise-700"
            >
              {@overview.series.attendee_email}
            </a>
          </Containers.detail_line>
          <Containers.detail_line
            variant={:tile}
            icon="hero-arrow-path"
            label={dgettext("dashboard_booking_series", "Rhythm")}
          >
            {rule(@overview, @timezone, @time_format) ||
              dgettext("dashboard_booking_series", "Times chosen one by one")}
          </Containers.detail_line>
          <Containers.detail_line
            :if={@overview.payment}
            variant={:tile}
            icon="hero-credit-card"
            label={dgettext("dashboard_booking_series", "Payment")}
            data-testid="series-payment"
          >
            {dgettext("dashboard_booking_series", "%{amount} paid",
              amount: format_amount(@overview.payment.amount_cents, @overview.payment.currency)
            )}
            <span class="block text-tymeslot-500">
              {dgettext("dashboard_booking_series", "%{amount} refunded so far",
                amount:
                  format_amount(
                    @overview.payment.refunded_amount_cents,
                    @overview.payment.currency
                  )
              )}
            </span>
          </Containers.detail_line>
        </div>

        <ol class="divide-y-2 divide-tymeslot-50 rounded-token-2xl border-2 border-tymeslot-50">
          <li
            :for={session <- @overview.sessions}
            id={"series-session-#{session.meeting.id}"}
            class="flex flex-col sm:flex-row sm:items-center gap-3 p-4"
          >
            <div class="flex-1 min-w-0">
              <p class="text-token-xs font-bold uppercase tracking-wide text-tymeslot-400">
                {dgettext("dashboard_booking_series", "Session %{position} of %{count}",
                  position: session.position,
                  count: @overview.series.occurrences_count
                )}
              </p>
              <p class="font-semibold text-tymeslot-900">
                {Helpers.format_meeting_date(session.meeting, @timezone)}
              </p>
              <p class="text-token-sm text-turquoise-600">
                {Helpers.format_meeting_time(session.meeting, @timezone, @time_format)}
              </p>
            </div>
            <div class="flex flex-wrap items-center gap-2">
              <MeetingStatusBadge.status_badges meeting={session.meeting} />
              <.session_actions
                :if={session.status == :upcoming}
                meeting={session.meeting}
                target={@target}
              />
            </div>
          </li>
        </ol>
      </div>

      <:footer :if={@overview}>
        <div class="flex flex-col-reverse sm:flex-row sm:items-center sm:justify-between gap-3">
          <Buttons.action_button
            variant={:secondary}
            class="w-full sm:w-auto"
            phx-click={JS.push("series:hide", target: @target)}
          >
            {dgettext("dashboard_booking_series", "Close")}
          </Buttons.action_button>
          <p :if={@overview.open_request} class="text-token-sm text-tymeslot-500">
            {dgettext(
              "dashboard_booking_series",
              "This series is waiting for your answer. Approve or decline it from its card."
            )}
          </p>
          <Buttons.action_button
            :if={!@overview.open_request and @overview.upcoming > 0}
            variant={:danger_soft}
            icon="hero-x-mark"
            class="w-full sm:w-auto"
            phx-click={JS.push("series:ask_cancel", target: @target)}
            data-testid="cancel-remaining-sessions"
          >
            {dgettext("dashboard_booking_series", "Cancel remaining sessions")}
          </Buttons.action_button>
        </div>
      </:footer>
    </Modal.modal>
    """
  end

  attr :meeting, :map, required: true
  attr :target, :any, required: true

  # The session's card actions, each closing this modal to open its own.
  defp session_actions(assigns) do
    ~H"""
    <Buttons.action_button
      :if={Helpers.can_reschedule?(@meeting)}
      variant={:secondary}
      size={:sm}
      icon="hero-arrows-right-left"
      phx-click={
        "series:hide"
        |> JS.push(target: @target)
        |> JS.push("show_reschedule_modal", value: %{id: @meeting.id}, target: @target)
      }
    >
      {dgettext("dashboard_bookings", "Reschedule")}
    </Buttons.action_button>
    <Buttons.action_button
      :if={Helpers.can_cancel?(@meeting)}
      variant={:danger_soft}
      size={:sm}
      icon="hero-x-mark"
      data-testid="series-session-cancel"
      phx-click={
        "series:hide"
        |> JS.push(target: @target)
        |> JS.push("show_cancel_modal", value: %{id: @meeting.id}, target: @target)
      }
    >
      {dgettext("dashboard_bookings", "Cancel")}
    </Buttons.action_button>
    """
  end

  defp type_name(%{meeting_type: %{name: name}}), do: name
  defp type_name(_series), do: nil

  # The rhythm read at each session's own time in the host's zone: one
  # phrase while every session keeps it, the rhythm alone once one was
  # moved, as the booker's series page words it.
  defp rule(%{series: series, sessions: sessions}, timezone, time_format) do
    locale = Gettext.get_locale(TymeslotWeb.Gettext)

    phrases =
      sessions
      |> Enum.map(fn session ->
        local = DateTimeUtils.convert_to_timezone(session.start_time, timezone)
        BookingSeries.describe_rule(series, locale, first_start: local, time_format: time_format)
      end)
      |> Enum.uniq()

    case phrases do
      [phrase] -> phrase
      _moved -> BookingSeries.describe_rule(series, locale)
    end
  end
end
