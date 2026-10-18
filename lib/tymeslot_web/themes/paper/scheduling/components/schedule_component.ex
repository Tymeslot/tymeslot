defmodule TymeslotWeb.Themes.Paper.Scheduling.Components.ScheduleComponent do
  @moduledoc """
  Paper's schedule screen, the journey's second moment, collecting the slot,
  the answers and the attendee: one card holding the meeting's details and a
  picker, the actions bar, and once a time is picked, the details part (beside the details column in the picker's place on a wide month card, below the picker otherwise)
  (`Paper.Scheduling.Details`: every question at once, then the form, and
  one submit for both).
  The organiser's calendar view option (`Options.CalendarView`, read from
  `@theme_tokens.media[:calendar_view]`; no tokens or no setting is a month)
  decides the picker.

  A month (`data-calendar-view="month"`): the timezone picker, then the month
  calendar and the chosen day's times (the shared `SlotList`): the visitor
  sees the zone before any time. The times' heading and prompt are in
  Paper's voice, and a month with no free day drops the prompt, so its
  "No times available this month" stands alone. The card lays them
  out by its own width (`schedule.css`): one column, then the details beside
  the picker, then details, calendar and times side by side.

  A week (`paper-card--week`, `data-calendar-view="week"`): the heading, the
  timezone picker and the shared `WeekGrid` (`data-testid="paper-week"`),
  where one click on a time picks the day and the time together. The card is
  wider, the details stand beside the week once seven days fit and become a
  compact row above it before (`week.css`), and the actions bar names the
  chosen day and time (`data-testid="paper-selection"`, announced politely).

  For a group type the details say how many people it takes
  (`GroupSession.hint`), and a seat move names the spot it is moving above
  both views (`GroupSession.seat_move_notice`, right under the brand). Each
  time shows its free seats, the month's through `SlotList` and the week's
  through `WeekGrid`, both given the meeting type.

  There is no Next: picking a time opens the details part. The actions bar
  (`data-testid="schedule-actions"`) holds the one Back, shown to a visitor
  who came through the overview, which goes straight to the meeting types.
  The questions' events (`answer`, `multi_toggle`, each naming its
  question) go to the shared questions engine (`CustomQuestions.Events`);
  the `next_step` a question's form sends on Enter is dropped, so the
  questions never step and Back always leaves; every other event goes to
  `StepEvents`.

  The calendar's buttons carry the class names and test ids the shared
  suites and the visual harness drive: `calendar-day` with `data-date`,
  `calendar-day--selected`, `calendar-day--other-month`, `calendar-day--today`
  and `calendar-day--loading`, `calendar-nav-button` on the month arrows, and
  `calendar-month-label` on the month between them. The week's are the
  grid's own (`week-slot` with `data-date` and `data-time`).
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Tymeslot.Timezones
  alias TymeslotWeb.Helpers.LocationIcons
  alias TymeslotWeb.Live.Scheduling.CalendarHelpers
  alias TymeslotWeb.Live.Scheduling.CalendarNavigation
  alias TymeslotWeb.Themes.Paper.Components
  alias TymeslotWeb.Themes.Paper.Scheduling.Details
  alias TymeslotWeb.Themes.Shared.BookingText
  alias TymeslotWeb.Themes.Shared.Components.GroupSession
  alias TymeslotWeb.Themes.Shared.Components.SlotList
  alias TymeslotWeb.Themes.Shared.Components.TimezonePicker
  alias TymeslotWeb.Themes.Shared.Components.WeekGrid
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Events
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.StepEvents

  import TymeslotWeb.Components.FlagHelpers, only: [timezone_flag: 1]

  @question_events ~w(answer multi_toggle)
  @pick_events ~w(select_time select_slot)

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  # Selection is decided by the shared scheduling LiveView, which owns
  # `selected_date` and `selected_time` and passes them back down; a
  # question's answer goes through the shared questions engine.
  @impl Phoenix.LiveComponent
  def handle_event(event, params, socket) when event in @question_events,
    do: Events.handle_event(event, params, socket)

  # The visitor's own pick of a time: from here on the details heading may
  # take the focus when it appears (`Details.book/1`). The screen stays one
  # moment, so the runtime's `:journey_focus` never changes on a pick; this
  # flag is the same rule at the component's level. A deep link to /book
  # never sends a pick, so it never moves the focus on load.
  def handle_event(event, params, socket) when event in @pick_events do
    socket
    |> assign(:focus_details, true)
    |> assign(:pick_seq, (socket.assigns[:pick_seq] || 0) + 1)
    |> then(&StepEvents.handle_event(event, params, &1))
  end

  # Enter in a question's field submits its form with `next_step`. The
  # screen has no way on, and stepping the questions would make Back step
  # back through them instead of leaving, so it is dropped.
  def handle_event("next_step", _params, socket), do: {:noreply, socket}

  def handle_event(event, params, socket), do: StepEvents.handle_event(event, params, socket)

  @impl Phoenix.LiveComponent
  def render(assigns) do
    view = calendar_view(assigns.theme_tokens)
    days = month_days(view, assigns)

    assigns =
      assign(assigns,
        view: view,
        week_empty: week_empty?(assigns),
        stage: stage(assigns),
        show_back: assigns[:entered_via_overview] == true,
        chosen: not is_nil(assigns.selected_date) and not is_nil(assigns.selected_time),
        duration_text: BookingText.duration_label(assigns),
        price:
          BookingText.price_label(assigns.meeting_type, assigns.host_currency, assigns.locale),
        days: days,
        month_empty:
          view == "month" and assigns.availability_status == :loaded and days != [] and
            not Enum.any?(days, &bookable?/1)
      )

    ~H"""
    <section
      id={"#{@moment}-step"}
      class={["paper-card paper-card--wide booker-card", @view == "week" && "paper-card--week"]}
      data-locale={@locale}
      data-calendar-view={@view}
      data-testid="paper-schedule"
      data-moment={@moment}
      data-moment-state={@moment_state}
    >
      <Components.brand theme_tokens={@theme_tokens} />

      <GroupSession.seat_move_notice from={assigns[:reschedule_seat_from]} timezone={@user_timezone} />

      <div class={["paper-schedule", @view == "week" && "paper-schedule--week"]}>
        <.details
          organizer_profile={@organizer_profile}
          meeting_type={@meeting_type}
          duration_text={@duration_text}
          price={@price}
        />

        <div :if={@view == "week"} class="paper-week" data-testid="paper-week">
          <div class="paper-week__header">
            <h2 class="paper-week__title">
              {dpgettext("booking_voice", "paper", "Select a date and time")}
            </h2>
            <.timezone
              timezone={@user_timezone}
              open={@timezone_dropdown_open}
              search={@timezone_search}
              target={@myself}
            />
          </div>

          <WeekGrid.week_grid
            week_start={@current_week_start}
            week_slots={@week_slots}
            loading={@week_slots_loading}
            error={@week_slots_error}
            selected_date={@selected_date}
            selected_time={@selected_time}
            today={@calendar_today}
            user_timezone={@user_timezone}
            booking_window_days={@booking_window_days}
            landing_week={CalendarHelpers.landing_week(assigns)}
            target={@myself}
            theme_key={:paper}
            heading_tag="h2"
            meeting_type={@meeting_type}
          >
            <:before_days>
              <p
                :if={@week_empty}
                class="paper-calendar__notice paper-calendar__notice--empty"
                role="status"
                data-testid="paper-week-empty"
              >
                {dpgettext("booking_voice", "paper", "No times available this week")}
              </p>
            </:before_days>
          </WeekGrid.week_grid>
        </div>

        <div :if={@view == "month"} class="paper-picker">
          <.timezone
            timezone={@user_timezone}
            open={@timezone_dropdown_open}
            search={@timezone_search}
            target={@myself}
          />

          <.calendar
            days={@days}
            year={@current_year}
            month={@current_month}
            week_start={@week_start}
            timezone={@user_timezone}
            booking_window_days={@booking_window_days}
            availability_status={@availability_status}
            empty={@month_empty}
            selected_date={@selected_date}
            target={@myself}
          />

          <div class="paper-slots">
            <SlotList.slot_list
              selected_date={@selected_date}
              selected_time={@selected_time}
              available_slots={@available_slots}
              loading_slots={@loading_slots}
              calendar_error={@calendar_error}
              slot_interval_minutes={@slot_interval_minutes}
              duration_minutes={@duration_minutes}
              expanded_hour={@expanded_hour}
              meeting_type={@meeting_type}
              target={@myself}
              theme_key={:paper}
              prompt={not @month_empty}
              heading_tag="h2"
              period_tag="h3"
            />
          </div>
        </div>

        <Details.book :if={@stage != :none} {assigns} target={@myself} />
      </div>

      <div
        :if={@show_back or @view == "week"}
        class={["paper-actions", @show_back && "paper-actions--split"]}
        data-testid="schedule-actions"
      >
        <button
          :if={@show_back}
          type="button"
          class="paper-button paper-button--quiet"
          phx-click="back_step"
          phx-target={@myself}
          data-testid="back-step"
          data-intent="back"
          disabled={assigns[:submitting]}
        >
          <.icon name="hero-arrow-left-mini" class="paper-button__icon" />
          {dgettext("booking", "Back")}
        </button>
        <p
          :if={@view == "week"}
          class="paper-selection"
          aria-live="polite"
          data-testid="paper-selection"
        >
          <%= if @chosen do %>
            <span class="paper-selection__date">
              {LocalizationHelpers.format_full_date_label(@selected_date)}
            </span>
            <span class="paper-selection__time">
              {LocalizationHelpers.format_slot_label(@selected_time)}
            </span>
          <% else %>
            <span class="paper-selection__prompt">{dpgettext(
              "booking_voice",
              "paper",
              "Select a time"
            )}</span>
          <% end %>
        </p>
      </div>
    </section>
    """
  end

  # What follows the picker: nothing until a time is picked; then the
  # details part (the questions, if any, and the form below them), once the
  # form exists: the runtime enters the attendee as the time is picked.
  defp stage(%{selected_date: date, selected_time: time} = assigns)
       when is_binary(date) and is_binary(time) do
    if match?(%Phoenix.HTML.Form{}, assigns[:form]), do: :details, else: :none
  end

  defp stage(_assigns), do: :none

  # The organiser's calendar view; no tokens, or none resolved, is a month.
  defp calendar_view(%{media: %{calendar_view: "week"}}), do: "week"
  defp calendar_view(_theme_tokens), do: "month"

  # The month calendar's days, worked out only when the month is on show.
  defp month_days("week", _assigns), do: []

  defp month_days("month", assigns) do
    CalendarHelpers.get_calendar_days(
      assigns.user_timezone,
      assigns.current_year,
      assigns.current_month,
      assigns.week_start,
      assigns.organizer_profile,
      assigns.month_availability_map,
      assigns.meeting_type
    )
  end

  # A loaded week with no free time on any day. A week not yet asked for
  # (nil), loading or failed says nothing of the kind.
  defp week_empty?(%{week_slots: slots} = assigns) when is_map(slots) and map_size(slots) > 0,
    do:
      assigns[:week_slots_loading] != true and is_nil(assigns[:week_slots_error]) and
        Enum.all?(Map.values(slots), &(&1 == []))

  defp week_empty?(_assigns), do: false

  attr :organizer_profile, :map, required: true
  attr :meeting_type, :map, default: nil
  attr :duration_text, :string, required: true
  attr :price, :string, default: nil

  defp details(assigns) do
    assigns =
      assign(assigns,
        locations: MeetingTypes.location_options(assigns.meeting_type),
        description: description(assigns.meeting_type)
      )

    ~H"""
    <aside class="paper-details">
      <Components.avatar profile={@organizer_profile} size={:sm} />
      <p class="paper-details__organiser">{Profiles.display_name(@organizer_profile)}</p>
      <h1 :if={@meeting_type} class="paper-details__title">{@meeting_type.name}</h1>
      <ul class="paper-facts" role="list">
        <Components.fact icon="hero-clock">{@duration_text}</Components.fact>
        <Components.fact :for={location <- @locations} icon={LocationIcons.icon(location.kind)}>
          {location.label}
        </Components.fact>
        <Components.fact :if={@price} icon="hero-banknotes">{@price}</Components.fact>
      </ul>
      <GroupSession.hint meeting_type={@meeting_type} />
      <p :if={@description} class="paper-details__description">{@description}</p>
    </aside>
    """
  end

  attr :days, :list, required: true
  attr :year, :integer, required: true
  attr :month, :integer, required: true
  attr :week_start, :atom, required: true, doc: "the flow's `:week_start`"
  attr :timezone, :string, required: true
  attr :booking_window_days, :integer, required: true
  attr :availability_status, :any, default: nil
  attr :empty, :boolean, default: false
  attr :selected_date, :string, default: nil
  attr :target, :any, required: true

  defp calendar(assigns) do
    ~H"""
    <div class="paper-calendar">
      <div class="paper-calendar__header">
        <h2 class="paper-calendar__title">
          {dpgettext("booking_voice", "paper", "Select a date and time")}
        </h2>
        <div class="paper-calendar__nav">
          <button
            type="button"
            class="calendar-nav-button paper-calendar__nav-button"
            phx-click="prev_month"
            data-intent="earlier"
            phx-target={@target}
            aria-label={CalendarNavigation.month_nav_label(:prev)}
            disabled={CalendarNavigation.prev_month_disabled?(@year, @month, @timezone)}
          >
            <.icon name="hero-chevron-left-mini" class="paper-calendar__nav-icon" />
          </button>
          <span class="calendar-month-label paper-calendar__month" aria-live="polite">
            {LocalizationHelpers.get_month_year_display(@year, @month)}
          </span>
          <button
            type="button"
            class="calendar-nav-button paper-calendar__nav-button"
            phx-click="next_month"
            data-intent="later"
            phx-target={@target}
            aria-label={CalendarNavigation.month_nav_label(:next)}
            disabled={
              CalendarNavigation.next_month_disabled?(@year, @month, @timezone, @booking_window_days)
            }
          >
            <.icon name="hero-chevron-right-mini" class="paper-calendar__nav-icon" />
          </button>
        </div>
      </div>

      <p :if={@availability_status == :error} class="paper-calendar__notice" role="status">
        {dgettext("booking", "Calendar is loading slowly")}
      </p>

      <p
        :if={@empty}
        class="paper-calendar__notice paper-calendar__notice--empty"
        role="status"
        data-testid="paper-month-empty"
      >
        {dpgettext("booking_voice", "paper", "No times available this month")}
      </p>

      <div class="paper-calendar__weekdays" aria-hidden="true">
        <span :for={weekday <- LocalizationHelpers.weekday_headings(@week_start)}>{weekday}</span>
      </div>

      <div class="paper-calendar__grid">
        <button
          :for={day <- @days}
          type="button"
          class={[
            "calendar-day",
            @selected_date == day[:date] && "calendar-day--selected",
            !day[:current_month] && "calendar-day--other-month",
            day[:today] && "calendar-day--today",
            Map.get(day, :loading, false) && "calendar-day--loading"
          ]}
          data-testid="calendar-day"
          data-date={day[:date]}
          data-fact={day[:current_month] && "date"}
          data-value={day[:current_month] && day[:date]}
          phx-click="select_date"
          phx-value-date={day[:date]}
          phx-target={@target}
          disabled={not bookable?(day)}
          aria-label={LocalizationHelpers.format_full_date_label(day[:date])}
          aria-current={day[:today] && "date"}
          aria-pressed={to_string(@selected_date == day[:date])}
        >
          <span class="calendar-day__number" aria-hidden="true">{day[:day]}</span>
        </button>
      </div>
    </div>
    """
  end

  attr :timezone, :string, required: true
  attr :open, :boolean, required: true
  attr :search, :string, default: ""
  attr :target, :any, required: true

  defp timezone(assigns) do
    ~H"""
    <div class="paper-timezone">
      <%!-- Visual label only: the trigger carries its own accessible name,
           so this must not be a <label>. --%>
      <p class="paper-timezone__label" aria-hidden="true">{dgettext("booking", "Your timezone")}</p>
      <TimezonePicker.timezone_picker open={@open} search={@search} target={@target}>
        <:trigger>
          <.timezone_flag timezone={@timezone} class="paper-tz__flag" fallback_icon="🌐" />
          <span class="paper-tz__name">{Timezones.format(@timezone)}</span>
          <.icon name="hero-chevron-down-mini" class="paper-tz__chevron" />
        </:trigger>
      </TimezonePicker.timezone_picker>
    </div>
    """
  end

  # A day the booker can pick: in this month, not past, available, and no
  # longer loading.
  defp bookable?(day) do
    day[:current_month] == true and day[:available] == true and day[:past] != true and
      Map.get(day, :loading, false) != true
  end

  defp description(%{description: text}) when is_binary(text) do
    if String.trim(text) == "", do: nil, else: text
  end

  defp description(_meeting_type), do: nil
end
