defmodule TymeslotWeb.Themes.Shared.SeriesParts do
  @moduledoc """
  The pieces every theme's series moment and series confirmation are made
  of (`Journey.Facts.Series`): the rhythm in words, the sessions with how
  each stands, the notices, the total of a paid series, the flexible
  picker's day and time buttons, and the booked sessions with their links.

  The markup is theme-neutral, styled through each theme's tokens by
  `assets/css/scheduling/shared/components/series.css`. The strings live in
  the `booking_series` domain beside the rhythm phrases they sit with.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  use TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  alias Phoenix.LiveView.JS

  alias Tymeslot.Bookings.MeetingLinks
  alias Tymeslot.BookingSeries
  alias Tymeslot.Meetings.Approval
  alias TymeslotWeb.Components.PaymentHelpers
  alias TymeslotWeb.Live.Scheduling.Handlers.BookingErrorMessage
  alias TymeslotWeb.Themes.Shared.BookingText
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  @total_id "series-total-amount"

  @doc "\"5 sessions\", in the page's language."
  @spec count_label(pos_integer()) :: String.t()
  def count_label(count),
    do: dngettext("booking_series", "%{count} session", "%{count} sessions", count)

  @doc """
  The short phrase for how a session stands: available, being checked, or
  why it cannot be booked (`Occurrence.reason()`). A session not yet
  checked (a flexible series still short of its sessions) shows none.
  """
  @spec status_label(term()) :: String.t()
  def status_label(:available), do: dgettext("booking_series", "Available")
  def status_label(:pending), do: dgettext("booking_series", "Checking")
  def status_label({:unavailable, reason}), do: reason_label(reason)

  @doc "Why a session cannot be booked, in a few words."
  @spec reason_label(atom()) :: String.t()
  def reason_label(reason) when reason in [:booked, :calendar_busy],
    do: dgettext("booking_series", "Not available")

  def reason_label(:outside_schedule), do: dgettext("booking_series", "Not offered on this day")
  def reason_label(:limit_reached), do: dgettext("booking_series", "Fully booked")
  def reason_label(:session_full), do: dgettext("booking_series", "Full")
  def reason_label(:beyond_series_span), do: dgettext("booking_series", "Too far ahead")
  def reason_label(:too_far_ahead), do: dgettext("booking_series", "Not open for booking yet")
  def reason_label(:too_soon), do: dgettext("booking_series", "Too soon to book")
  def reason_label(:in_past), do: dgettext("booking_series", "Already passed")
  def reason_label(:no_session), do: dgettext("booking_series", "No session at this time")

  def reason_label(:already_booked),
    do: dgettext("booking_series", "You already have this session")

  def reason_label(:seat_held), do: dgettext("booking_series", "Your payment is still open")

  def reason_label(:overlaps_session),
    do: dgettext("booking_series", "Overlaps another of your sessions")

  def reason_label(_other), do: dgettext("booking_series", "Not available")

  @doc """
  What a paid series costs in all: the type's price times `count`, in the
  organiser's currency, or nil for a free type.
  """
  @spec total_label(map() | nil, String.t() | nil, String.t(), pos_integer()) ::
          String.t() | nil
  def total_label(meeting_type, currency, locale, count) do
    with true <- BookingText.price_label(meeting_type, currency, locale) != nil,
         cents when is_integer(cents) <- BookingSeries.total_cents(meeting_type, count) do
      PaymentHelpers.format_amount(cents, currency, locale)
    else
      _free -> nil
    end
  end

  @doc """
  The submit of a series booking: "Book 4 sessions", or "Request 4
  sessions" on a type the host approves first.
  """
  @spec submit_label(map() | nil, pos_integer()) :: String.t()
  def submit_label(meeting_type, count) do
    if Approval.required?(meeting_type),
      do:
        dngettext(
          "booking_series",
          "Request %{count} session",
          "Request %{count} sessions",
          count
        ),
      else: dngettext("booking_series", "Book %{count} session", "Book %{count} sessions", count)
  end

  @doc "The id of the total's amount, for a submit's `aria-describedby`."
  @spec total_id() :: String.t()
  def total_id, do: @total_id

  attr :meeting_type, :any, required: true
  attr :first_start, :any, required: true, doc: "the first session, a `DateTime`"
  attr :timezone, :string, required: true
  attr :locale, :string, required: true
  attr :class, :any, default: nil

  @doc "The rhythm of a recurring series in words; nothing for a flexible one."
  @spec rule(map()) :: Phoenix.LiveView.Rendered.t()
  def rule(assigns) do
    assigns = assign(assigns, :text, rule_text(assigns))

    ~H"""
    <p :if={@text} class={["series-rule", @class]} data-testid="series-rule">
      <.icon name="hero-arrow-path-mini" class="series-rule-icon" />
      <span>{@text}</span>
    </p>
    """
  end

  # The day and time are named as the booker reads them.
  defp rule_text(
         %{meeting_type: %{series_mode: :recurring} = type, first_start: %DateTime{} = first} =
           assigns
       ) do
    {:ok, local} = LocalizationHelpers.to_attendee_datetime(first, assigns.timezone)
    BookingSeries.describe_rule(type, assigns.locale, first_start: local)
  end

  defp rule_text(_assigns), do: nil

  attr :rows, :list, required: true, doc: "`Journey.Facts.Series.rows/1`"
  attr :timezone, :string, required: true
  attr :checking, :boolean, default: false
  attr :removable, :boolean, default: false, doc: "a flexible series: every session but the first"

  attr :refocus, :boolean,
    default: false,
    doc: "take the focus as the list mounts (a session added)"

  attr :target, :any, default: nil

  @doc """
  The sessions, in order, each with how it stands. The first session is the
  slot picked; on a flexible series every other one has a remove button.
  """
  @spec occurrence_list(map()) :: Phoenix.LiveView.Rendered.t()
  def occurrence_list(assigns) do
    ~H"""
    <%!-- A new id per length remounts the list after a change of size, so
          the focus can move to it once a session was added. --%>
    <ol
      id={"series-occurrences-#{length(@rows)}"}
      class="series-list"
      data-testid="series-occurrences"
      aria-busy={to_string(@checking)}
      tabindex={@refocus && "-1"}
      phx-mounted={refocus(@refocus)}
    >
      <li
        :for={row <- @rows}
        id={"series-occurrence-#{row.position}"}
        class={["series-list__item", "series-list__item--#{status_class(row.status)}"]}
        data-testid="series-occurrence"
        data-status={status_class(row.status)}
      >
        <span class="series-list__position" aria-hidden="true">{row.position}</span>
        <span class="series-list__when">
          {LocalizationHelpers.format_meeting_datetime_compact(row.start, @timezone)}
        </span>
        <span
          :if={row.status != :pending or @checking}
          class={["series-status", "series-status--#{status_class(row.status)}"]}
        >
          <.icon
            :if={row.status == :available}
            name="hero-check-circle-mini"
            class="series-status-icon"
          />
          <.icon
            :if={match?({:unavailable, _reason}, row.status)}
            name="hero-x-circle-mini"
            class="series-status-icon"
          />
          {status_label(row.status)}
        </span>
        <button
          :if={@removable and row.position > 1}
          type="button"
          class="series-list__remove"
          phx-click="series_remove_start"
          phx-value-start={DateTime.to_iso8601(row.start)}
          phx-target={@target}
          data-testid="series-remove"
          aria-label={
            dgettext("booking_series", "Remove the session on %{when}",
              when: LocalizationHelpers.format_meeting_datetime_compact(row.start, @timezone)
            )
          }
        >
          <.icon name="hero-x-mark-mini" class="series-list__remove-icon" />
        </button>
      </li>
    </ol>
    """
  end

  defp status_class(:available), do: "available"
  defp status_class(:pending), do: "pending"
  defp status_class({:unavailable, _reason}), do: "unavailable"

  attr :rows, :list, required: true, doc: "`Journey.Facts.Series.rows/1`"
  attr :checking, :boolean, default: false

  @doc """
  The one polite live region of a series moment, rendered at all times: it
  says how the last check came out, so a screen reader hears the result of
  every change of the series without the list being read again.
  """
  @spec announcement(map()) :: Phoenix.LiveView.Rendered.t()
  def announcement(assigns) do
    assigns = assign(assigns, :text, announcement_text(assigns.rows, assigns.checking))

    ~H"""
    <p class="sr-only" role="status" aria-live="polite" data-testid="series-announcement">
      {@text}
    </p>
    """
  end

  defp announcement_text(_rows, true), do: dgettext("booking_series", "Checking availability…")

  defp announcement_text(rows, false) do
    judged = Enum.reject(rows, &(&1.status == :pending))
    lost = Enum.count(judged, &match?({:unavailable, _reason}, &1.status))

    cond do
      judged == [] ->
        ""

      lost > 0 ->
        dngettext(
          "booking_series",
          "%{count} session not available",
          "%{count} sessions not available",
          lost
        )

      true ->
        dngettext(
          "booking_series",
          "%{available} of %{count} session available",
          "%{available} of %{count} sessions available",
          length(judged),
          available: length(judged)
        )
    end
  end

  @doc """
  The binding that moves the focus to an element as it mounts, when the
  moment asks for it (`:series_refocus`, after a session was added), and
  nothing otherwise, so the page never takes the focus on load.
  """
  @spec refocus(boolean()) :: JS.t() | nil
  def refocus(true), do: JS.focus()
  def refocus(_no), do: nil

  attr :target, :any, default: nil

  attr :change_time, :any,
    default: nil,
    doc:
      "what \"Change time\" does: nil goes back a step (`back_step`, a paged journey's " <>
        "time picker); a `JS` command takes the booker to the picker on the same page"

  @doc """
  The notice a series with unavailable sessions shows, with the way back to
  the time picker.
  """
  @spec unavailable_notice(map()) :: Phoenix.LiveView.Rendered.t()
  def unavailable_notice(assigns) do
    ~H"""
    <div class="series-notice" role="status" data-testid="series-unavailable">
      <.icon name="hero-exclamation-triangle-mini" class="series-notice-icon" />
      <div class="series-notice-body">
        <p class="series-notice-text">
          {dgettext(
            "booking_series",
            "Some sessions aren't available at this time. Pick another time for your first session, or book fewer sessions."
          )}
        </p>
        <button
          type="button"
          class="series-notice-action"
          phx-click={@change_time || "back_step"}
          phx-target={if is_nil(@change_time), do: @target}
          data-testid="series-change-time"
        >
          {dgettext("booking_series", "Change time")}
        </button>
      </div>
    </div>
    """
  end

  attr :reason, :atom, required: true
  attr :target, :any, default: nil
  attr :retry_event, :string, default: "series_retry", doc: "what the retry sends"

  @doc """
  Why the series could not be checked: the host's calendar out of reach,
  or too many checks in a short while, with a retry; or sessions that
  overlap.
  """
  @spec check_error(map()) :: Phoenix.LiveView.Rendered.t()
  def check_error(assigns) do
    ~H"""
    <div class="series-notice" role="alert" data-testid="series-check-error">
      <.icon name="hero-exclamation-triangle-mini" class="series-notice-icon" />
      <div class="series-notice-body">
        <p class="series-notice-text">{check_error_text(@reason)}</p>
        <button
          :if={@reason in [:availability_unverifiable, :rate_limited]}
          type="button"
          class="series-notice-action"
          phx-click={@retry_event}
          phx-target={@target}
          data-testid={String.replace(@retry_event, "_", "-")}
        >
          {dgettext("booking_series", "Try again")}
        </button>
      </div>
    </div>
    """
  end

  # A visitor past the series check limit (`Series.charge_read/1`) is told
  # what a booker can act on, the same as for a calendar out of reach:
  # wait a moment and try again.
  defp check_error_text(reason) when reason in [:availability_unverifiable, :rate_limited],
    do:
      dgettext(
        "booking_series",
        "We couldn't check the host's calendar just now. Please try again in a moment."
      )

  defp check_error_text(reason), do: BookingErrorMessage.message(reason)

  attr :meeting_type, :any, required: true
  attr :currency, :string, default: nil
  attr :locale, :string, required: true
  attr :count, :integer, required: true
  attr :class, :any, default: nil

  attr :id, :any,
    default: @total_id,
    doc: "the id a submit's `aria-describedby` names; nil for a total no submit names"

  @doc "\"Total: €200.00\" below a paid series' sessions; nothing for a free type."
  @spec total(map()) :: Phoenix.LiveView.Rendered.t()
  def total(assigns) do
    assigns =
      assign(
        assigns,
        :amount,
        total_label(assigns.meeting_type, assigns.currency, assigns.locale, assigns.count)
      )

    ~H"""
    <p :if={@amount} id={@id} class={["series-total", @class]} data-testid="series-total">
      {dgettext("booking_series", "Total: %{amount}", amount: @amount)}
    </p>
    """
  end

  attr :days, :list, required: true, doc: "`SeriesPicker.days/1`"
  attr :day, :string, default: nil, doc: "the day whose times are on show"
  attr :timezone, :string, required: true
  attr :target, :any, default: nil

  @doc """
  The flexible picker's days that have a free time, and the chosen day's
  times; each time adds that session (`series_add_start`).
  """
  @spec picker_slots(map()) :: Phoenix.LiveView.Rendered.t()
  def picker_slots(assigns) do
    shown = Enum.find(assigns.days, &(&1.iso == assigns.day)) || List.first(assigns.days)
    assigns = assign(assigns, :shown, shown)

    ~H"""
    <div class="series-picker__body">
      <div class="series-picker__days" role="group" aria-label={dgettext("booking_series", "Days")}>
        <button
          :for={day <- @days}
          type="button"
          class={["slot-list__slot series-picker__day", @shown == day && "slot-list__slot--selected"]}
          phx-click="series_picker_day"
          phx-value-date={day.iso}
          phx-target={@target}
          aria-pressed={to_string(@shown == day)}
          data-testid="series-picker-day"
          data-date={day.iso}
        >
          {LocalizationHelpers.day_name_short(Date.day_of_week(day.date))} {day.date.day}
        </button>
      </div>
      <div
        :if={@shown}
        class="series-picker__times"
        role="group"
        aria-label={LocalizationHelpers.format_date(@shown.date)}
      >
        <button
          :for={time <- @shown.times}
          type="button"
          class="slot-list__slot series-picker__time"
          phx-click="series_add_start"
          phx-value-start={DateTime.to_iso8601(time.start)}
          phx-target={@target}
          data-fact="series"
          data-value={DateTime.to_iso8601(time.start)}
          data-testid="series-picker-time"
        >
          {LocalizationHelpers.format_slot_label(time.label)}
        </button>
      </div>
      <p :if={@days == []} class="series-picker__empty">
        {dgettext("booking_series", "No free times this week.")}
      </p>
    </div>
    """
  end

  attr :meetings, :list, required: true
  attr :timezone, :string, required: true
  attr :organizer_profile, :any, default: nil
  attr :links, :boolean, default: true, doc: "each session's reschedule and cancel links"

  @doc """
  The booked sessions, each with its own reschedule and cancel links where
  the booker has them: a one-to-one session, booked outright. A group
  session's links are the booker's seat's, which the series page gives; a
  request waiting on the host has none yet.
  """
  @spec booked_list(map()) :: Phoenix.LiveView.Rendered.t()
  def booked_list(assigns) do
    rows =
      assigns.meetings
      |> Enum.with_index(1)
      |> Enum.map(fn {meeting, position} ->
        %{
          position: position,
          start: meeting.start_time,
          links:
            if(assigns.links and own_links?(meeting),
              do: MeetingLinks.for_meeting(meeting, assigns.organizer_profile)
            )
        }
      end)

    assigns = assign(assigns, :rows, rows)

    ~H"""
    <ol class="series-list series-list--booked" data-testid="series-booked">
      <li
        :for={row <- @rows}
        id={"series-booked-#{row.position}"}
        class="series-list__item"
        data-testid="series-booked-session"
      >
        <span class="series-list__position" aria-hidden="true">{row.position}</span>
        <span class="series-list__body">
          <span class="series-list__when">
            {LocalizationHelpers.format_meeting_datetime_compact(row.start, @timezone)}
          </span>
          <span :if={row.links} class="series-list__links">
            <a href={row.links.reschedule_url} class="series-list__link">
              {dgettext("booking_series", "Reschedule")}
            </a>
            <a href={row.links.cancel_url} class="series-list__link">
              {dgettext("booking_series", "Cancel")}
            </a>
          </span>
        </span>
      </li>
    </ol>
    """
  end

  defp own_links?(%{capacity: capacity}) when is_integer(capacity) and capacity > 1, do: false
  defp own_links?(%{status: :confirmed, uid: uid}) when is_binary(uid), do: true
  defp own_links?(_meeting), do: false
end
