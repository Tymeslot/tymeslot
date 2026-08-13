defmodule TymeslotWeb.Dashboard.CalendarGrid.GridViews do
  @moduledoc """
  Day/week timed-grid view for the calendar grid, plus the public facade for the
  other view components. The month view, all-day row, status banners and guest
  badges live in focused modules under `CalendarGrid.Views.*`; `month_view/1` is
  re-exported here so existing callers keep a single entry point.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers
  alias TymeslotWeb.Dashboard.CalendarGrid.Views.AllDayRow
  alias TymeslotWeb.Dashboard.CalendarGrid.Views.EventBadges
  alias TymeslotWeb.Dashboard.CalendarGrid.Views.MonthView
  alias TymeslotWeb.Dashboard.CalendarGrid.Views.StatusBanners
  alias TymeslotWeb.Helpers.LocaleFormat

  @timed_views [:week, :three_day, :day]

  defdelegate month_view(assigns), to: MonthView

  attr :view, :atom, required: true
  attr :visible_days, :list, required: true
  attr :visible_events, :list, required: true
  attr :events, :list, required: true
  attr :integrations, :list, required: true
  attr :integration_colors, :map, required: true
  attr :calendar_colors, :map, required: true
  attr :hidden_integration_ids, :list, required: true
  attr :current_time, :any, required: true
  attr :user_timezone, :string, required: true
  attr :preferences, :any
  attr :stale_integrations, :list, required: true
  attr :oldest_sync_at, :any
  attr :syncing, :boolean, required: true
  attr :sync_total, :integer, required: true
  attr :sync_completed, :integer, required: true
  attr :date, :any, required: true
  attr :guest_rsvp_summaries, :map, default: %{}
  attr :myself, :any, required: true

  @spec week_day_view(map()) :: Phoenix.LiveView.Rendered.t()
  def week_day_view(assigns) do
    day_layouts =
      Map.new(assigns.visible_days, fn day -> {day, Helpers.layout_for_day(assigns, day)} end)

    day_clashes =
      Map.new(assigns.visible_days, fn day ->
        {day, Helpers.cross_integration_overlap_ids_for_day(assigns, day)}
      end)

    assigns =
      assigns
      |> assign(:col_count, Helpers.col_count(assigns))
      |> assign(:day_clashes, day_clashes)
      |> assign(:is_timed, assigns.view in @timed_views)
      |> assign(
        :today_visible?,
        today_in_visible?(assigns.visible_days, assigns.current_time, assigns.user_timezone)
      )
      |> assign(:current_top_rem, Helpers.top_rem(assigns.current_time, assigns.user_timezone))
      |> assign(:day_layouts, day_layouts)
      |> assign(:locale, Gettext.get_locale(TymeslotWeb.Gettext))

    ~H"""
    <StatusBanners.status_banners
      stale_integrations={@stale_integrations}
      syncing={@syncing}
      sync_total={@sync_total}
      sync_completed={@sync_completed}
      oldest_sync_at={@oldest_sync_at}
      myself={@myself}
    />

    <div class={if @is_timed, do: "contents", else: "hidden"}>
      <%!-- All-day banner row --%>
      <div
        id="calendar-allday-row"
        class="grid border-b border-tymeslot-200 bg-white"
        style={"grid-template-columns: var(--time-axis) repeat(#{@col_count}, 1fr)"}
      >
        <div class="text-token-xs text-tymeslot-500 flex items-end justify-end pr-2 pb-1">
          {dgettext("dashboard_calendar", "all-day")}
        </div>
        <AllDayRow.all_day_cell
          :for={day <- @visible_days}
          assigns_ref={assigns}
          day={day}
          myself={@myself}
        />
      </div>

      <%!-- Main scrollable area --%>
      <div
        id="calendar-drag-zone"
        phx-hook="CalendarDrag"
        phx-target={@myself}
        class="flex-1 overflow-y-auto overflow-x-auto relative"
        data-current-top-rem={@current_top_rem}
        data-show-now={to_string(@today_visible?)}
      >
        <%!-- Day column headers (sticky) --%>
        <div
          class="grid border-b border-tymeslot-200 sticky top-0 bg-white z-10 shadow-[0_1px_0_rgba(0,0,0,0.02)]"
          style={"grid-template-columns: var(--time-axis) repeat(#{@col_count}, 1fr)"}
        >
          <div class="flex items-center justify-end pr-2 sticky left-0 bg-white z-10">
            <span class="text-token-xs text-tymeslot-500">{Helpers.user_tz_abbr(assigns)}</span>
          </div>
          <div
            :for={day <- @visible_days}
            class={"text-center py-2 border-l border-tymeslot-200 #{Helpers.day_header_class(day, @user_timezone)}"}
          >
            <span :if={@view == :day} class="text-token-sm font-medium hidden sm:inline">{full_day_label(
              day,
              @locale
            )}</span>
            <span :if={@view == :day} class="text-token-sm font-medium sm:hidden">{short_day_label(
              day,
              @locale
            )}</span>
            <span :if={@view != :day} class="text-token-sm">{short_day_label(day, @locale)}</span>
          </div>
        </div>

        <%!-- Time grid (keyed on view+date to retrigger fade on navigation) --%>
        <div id="calendar-create-zone" phx-hook="CalendarCreate" phx-target={@myself}>
          <div id="calendar-resize-zone" phx-hook="CalendarResize" phx-target={@myself}>
            <div
              id={"calendar-time-grid-#{@view}-#{Date.to_iso8601(@date)}"}
              class="grid relative animate-fade-in"
              style={"grid-template-columns: var(--time-axis) repeat(#{@col_count}, 1fr)"}
            >
              <%!-- Time axis (sticky left) --%>
              <div class="relative sticky left-0 bg-white z-[5] border-r border-tymeslot-200">
                <div
                  :for={hour <- 0..23}
                  class="h-16 border-b border-tymeslot-200 flex items-start justify-end pr-2 pt-0.5"
                >
                  <span class="text-token-xs text-tymeslot-500">
                    {Helpers.format_hour(hour, assigns)}
                  </span>
                </div>
              </div>

              <%!-- Day columns --%>
              <div
                :for={day <- @visible_days}
                class="relative border-l border-tymeslot-200"
                data-day-col={Date.to_iso8601(day)}
                style="min-height: 96rem;"
              >
                <%!-- Hour grid lines --%>
                <div :for={_hour <- 0..23} class="h-16 border-b border-tymeslot-200"></div>
                <%!-- Events --%>
                <div
                  :for={{event, col_idx, total_cols} <- elem(Map.get(@day_layouts, day, {[], []}), 0)}
                  id={"event-#{event.id}-#{day}"}
                  class={"absolute rounded px-1 py-0.5 #{if @view == :day, do: "text-token-sm", else: "text-token-xs"} font-medium text-white overflow-hidden cursor-pointer hover:brightness-90 focus:outline-hidden focus:ring-2 focus:ring-turquoise-400 focus:ring-offset-1 group #{Helpers.color_for_event(assigns, event)} #{clash_marker_class(@day_clashes, day, event)}"}
                  style={"top: #{Helpers.top_rem(event.start_at, @user_timezone)}rem; height: #{Helpers.height_rem(event.start_at, event.end_at)}rem; left: #{Helpers.left_pct(col_idx, total_cols)}%; width: calc(#{Helpers.width_pct(total_cols)}% - 2px);"}
                  {Helpers.open_event_attrs(event)}
                  phx-target={@myself}
                  role="button"
                  tabindex="0"
                  aria-label={
                    dgettext("dashboard_calendar", "%{event}, %{time}",
                      event: event.summary || dgettext("dashboard_calendar", "Untitled event"),
                      time:
                        Helpers.format_display_time_range(
                          event,
                          Helpers.time_format(assigns),
                          @user_timezone
                        )
                    ) <> clash_label_suffix(@day_clashes, day, event)
                  }
                  data-draggable={to_string(not Helpers.booking?(event))}
                  data-event-id={event.id}
                  data-event-date={Date.to_iso8601(day)}
                  data-start-minutes={
                    DateTime.shift_zone!(event.start_at, @user_timezone)
                    |> then(&(&1.hour * 60 + &1.minute))
                  }
                  data-duration-minutes={
                    max(
                      15,
                      round(
                        DateTime.diff(
                          Map.get(event, :display_end_at, event.end_at),
                          Map.get(event, :display_start_at, event.start_at),
                          :second
                        ) / 60
                      )
                    )
                  }
                >
                  <div class="truncate font-semibold">
                    <.icon
                      :if={(Map.get(event, :reminders) || []) != []}
                      name="hero-bell-micro"
                      class="inline-block w-3 h-3 opacity-70 mr-0.5 align-text-bottom"
                    />{event.summary || dgettext("dashboard_calendar", "(No title)")}
                  </div>
                  <div class="opacity-80">
                    {Helpers.format_display_time_range(
                      event,
                      Helpers.time_format(assigns),
                      @user_timezone
                    )}
                  </div>
                  <div
                    :if={Helpers.booking?(event) && event.attendee_name}
                    class="opacity-80 truncate"
                  >
                    {event.attendee_name}
                  </div>
                  <img
                    :if={Map.get(event, :created_by_tymeslot)}
                    src="/images/brand/logo.svg"
                    alt="Tymeslot"
                    class="absolute top-0.5 right-0.5 w-3 h-3 opacity-60"
                  />
                  <EventBadges.event_guest_badge summary={
                    EventBadges.guest_summary_for_event(@guest_rsvp_summaries, event)
                  } />
                  <%!-- Enlarged invisible resize hit-target for touch; visual handle revealed on hover --%>
                  <div
                    :if={not Helpers.booking?(event)}
                    data-resize-handle
                    class="absolute bottom-0 left-0 right-0 h-3 cursor-s-resize touch-none"
                    aria-hidden="true"
                  >
                    <div class="absolute bottom-0 left-0 right-0 h-2 opacity-0 group-hover:opacity-100 bg-black/10 rounded-b">
                    </div>
                  </div>
                </div>

                <.overflow_chip
                  :for={
                    {overflow_cluster, idx} <-
                      day
                      |> overflow_clusters(elem(Map.get(@day_layouts, day, {[], []}), 1))
                      |> Enum.with_index()
                  }
                  cluster={overflow_cluster}
                  day={day}
                  user_timezone={@user_timezone}
                  key={"overflow-#{day}-#{idx}"}
                  myself={@myself}
                />

                <%!-- Current time indicator --%>
                <div
                  :if={
                    Date.compare(
                      day,
                      DateTime.to_date(DateTime.shift_zone!(@current_time, @user_timezone))
                    ) == :eq
                  }
                  id={"current-time-#{day}"}
                  class="absolute left-0 right-0 z-20 pointer-events-none"
                  style={"top: #{@current_top_rem}rem"}
                  aria-hidden="true"
                >
                  <div class="h-0.5 bg-red-500 relative">
                    <div class="w-2.5 h-2.5 rounded-full bg-red-500 absolute -left-1.5 -top-[0.1875rem]">
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- "Jump to now" pill (shown by CalendarDrag hook when marker off-screen) --%>
        <button
          id="calendar-jump-to-now"
          type="button"
          phx-click={JS.dispatch("calendar:scroll-to-current", to: "#calendar-drag-zone")}
          class="hidden fixed bottom-6 right-6 z-30 flex items-center gap-1.5 px-3 py-2 rounded-token-full bg-turquoise-600 hover:bg-turquoise-700 text-white text-token-sm font-medium shadow-lg shadow-turquoise-500/30 focus:outline-hidden focus:ring-2 focus:ring-turquoise-400 focus:ring-offset-2"
        >
          <.icon name="hero-calendar-days" class="w-4 h-4" />
          {dgettext("dashboard_calendar", "Now")}
        </button>
      </div>
    </div>
    """
  end

  # ---------- Cross-calendar clash marker ----------

  # An outline, never a colour. Colour on this element is already spoken for:
  # `color_for_event/2` resolves it through a four-level precedence and it is
  # how an organiser tells which calendar an event came from, so repainting a
  # clashing event would delete the very signal that makes the clash worth
  # noticing. The marker is therefore additive — it lands beside the
  # `bg-calendar-*` class rather than in place of it.
  #
  # `outline-*` rather than `ring-*` deliberately. The element already carries
  # `focus:ring-2 focus:ring-turquoise-400`, and a ring here would be the same
  # CSS property as that focus ring: keyboard-focusing a clashing event would
  # swap one meaning for the other, and whichever utility Tailwind emitted last
  # would win. An outline is a separate property, so the two stack and a focused
  # clashing event still reads as both.
  #
  # A negative outline offset keeps the outline inside the block. Drawn outside
  # it would overlap the neighbouring column — which in a clash is the very
  # event being clashed with — and read as though it enclosed both.
  @clash_marker "outline outline-2 outline-dashed outline-white/90 -outline-offset-2"

  defp clash_marker_class(day_clashes, day, event) do
    if clashing?(day_clashes, day, event), do: @clash_marker, else: ""
  end

  # A dashed outline says nothing to a screen reader, so the same fact is
  # appended to the label the event already exposes. Appended rather than folded
  # into the "%{event}, %{time}" msgid: that msgid is shared with the agenda
  # view, where the marker does not apply, and giving it a third interpolation
  # would oblige every locale to restate the time format to say a thing the
  # agenda never says.
  defp clash_label_suffix(day_clashes, day, event) do
    if clashing?(day_clashes, day, event) do
      ", " <> dgettext("dashboard_calendar", "overlaps an event on another calendar")
    else
      ""
    end
  end

  defp clashing?(day_clashes, day, event) do
    day_clashes
    |> Map.get(day, MapSet.new())
    |> MapSet.member?(event.id)
  end

  # ---------- Overflow chip (3+ overlapping events) ----------

  attr :cluster, :map, required: true
  attr :day, :any, required: true
  attr :user_timezone, :string, required: true
  attr :key, :string, required: true
  attr :myself, :any, required: true

  defp overflow_chip(assigns) do
    first_event = List.first(assigns.cluster.events)

    assigns =
      assigns
      |> assign(:first_event, first_event)
      |> assign(:open_attrs, first_event && Helpers.open_event_attrs(first_event))

    ~H"""
    <button
      :if={@first_event}
      id={@key}
      type="button"
      {@open_attrs}
      phx-target={@myself}
      class="absolute right-0.5 z-10 px-1.5 py-0.5 rounded-full bg-tymeslot-900/80 hover:bg-tymeslot-900 text-white text-token-xs font-semibold shadow-sm focus:outline-hidden focus:ring-2 focus:ring-turquoise-400"
      style={"top: #{Helpers.top_rem(@cluster.start_at, @user_timezone)}rem;"}
      aria-label={
        dngettext(
          "dashboard_calendar",
          "%{count} more event",
          "%{count} more events",
          length(@cluster.events),
          count: length(@cluster.events)
        )
      }
    >
      +{length(@cluster.events)}
    </button>
    """
  end

  # Group overflow events into time-contiguous clusters so we can render one chip per cluster.
  defp overflow_clusters(_day, overflow_events) do
    events = Enum.sort_by(overflow_events, & &1.start_at, DateTime)

    events
    |> Enum.reduce([], fn event, clusters ->
      case clusters do
        [] ->
          [%{start_at: event.start_at, end_at: event.end_at, events: [event]}]

        [head | rest] ->
          if DateTime.compare(event.start_at, head.end_at) == :lt do
            updated = %{
              start_at: head.start_at,
              end_at: max_datetime(head.end_at, event.end_at),
              events: [event | head.events]
            }

            [updated | rest]
          else
            [%{start_at: event.start_at, end_at: event.end_at, events: [event]} | clusters]
          end
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn cluster -> Map.update!(cluster, :events, &Enum.reverse/1) end)
  end

  defp max_datetime(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)

  # Localised day-column header labels (weekday/month rendered in the active locale).
  defp full_day_label(day, locale) do
    "#{LocaleFormat.format_weekday_name(Date.day_of_week(day), locale, :full)}, " <>
      "#{LocaleFormat.format_month_name(day.month, locale)} #{day.day}, #{day.year}"
  end

  defp short_day_label(day, locale) do
    "#{LocaleFormat.format_weekday_name(Date.day_of_week(day), locale, :short)} #{day.day}"
  end

  defp today_in_visible?(visible_days, current_time, timezone) do
    today = current_time |> DateTime.shift_zone!(timezone) |> DateTime.to_date()
    Enum.any?(visible_days, &(Date.compare(&1, today) == :eq))
  end
end
