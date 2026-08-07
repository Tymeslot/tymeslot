defmodule TymeslotWeb.Dashboard.CalendarGrid.Views.MonthView do
  @moduledoc "Month grid view function component for the calendar grid."

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers
  alias TymeslotWeb.Dashboard.CalendarGrid.Views.EventBadges
  alias TymeslotWeb.Helpers.LocaleFormat

  # Vertical rhythm for the bar band, in rem. The day number occupies the top
  # `@band_top`; each multi-day/all-day bar lane is `@lane_h` tall with the bar
  # itself `@bar_h`. Single-day chips are pushed below the reserved lane band.
  @band_top 1.75
  @lane_h 1.25
  @bar_h 1.1

  attr :view, :atom, required: true
  attr :visible_days, :list, required: true
  attr :visible_events, :list, required: true
  attr :integrations, :list, required: true
  attr :integration_colors, :map, required: true
  attr :calendar_colors, :map, required: true
  attr :hidden_integration_ids, :list, required: true
  attr :date, :any, required: true
  attr :user_timezone, :string, required: true
  attr :preferences, :any
  attr :guest_rsvp_summaries, :map, default: %{}
  attr :myself, :any, required: true

  @spec month_view(map()) :: Phoenix.LiveView.Rendered.t()
  def month_view(assigns) do
    ~H"""
    <div
      id="calendar-month-grid"
      class={if @view == :month, do: "flex-1 overflow-auto", else: "hidden"}
    >
      <%!-- Day-of-week headers --%>
      <div
        class="grid border-b border-tymeslot-200 bg-white sticky top-0 z-10"
        style={
          if Helpers.show_week_numbers?(assigns),
            do: "grid-template-columns: 2rem repeat(7, 1fr)",
            else: "grid-template-columns: repeat(7, 1fr)"
        }
      >
        <div
          :if={Helpers.show_week_numbers?(assigns)}
          class="text-center text-token-xs font-semibold text-tymeslot-500 py-1 sm:py-2"
        >
          {dgettext("dashboard_calendar", "Wk")}
        </div>
        <div
          :for={day_name <- Helpers.day_name_headers(assigns)}
          class="text-center text-token-xs font-semibold text-tymeslot-600 py-1 sm:py-2 uppercase tracking-wide"
        >
          <span class="hidden sm:inline">{day_name}</span>
          <span class="sm:hidden">{String.first(day_name)}</span>
        </div>
      </div>

      <%!-- One row per week (keyed on month to retrigger fade on navigation).
            Each week is its own positioning context so multi-day / all-day bars
            can span its day columns. --%>
      <div
        id={"month-grid-#{@date.year}-#{@date.month}"}
        class="animate-fade-in border-l border-t border-tymeslot-200"
      >
        <.month_week
          :for={week_days <- Enum.chunk_every(@visible_days, 7)}
          week_days={week_days}
          assigns_ref={assigns}
          user_timezone={@user_timezone}
          myself={@myself}
        />
      </div>
    </div>
    """
  end

  attr :week_days, :list, required: true
  attr :assigns_ref, :map, required: true
  attr :user_timezone, :string, required: true
  attr :myself, :any, required: true

  defp month_week(assigns) do
    layout = Helpers.week_layout(assigns.assigns_ref, assigns.week_days)

    assigns =
      assigns
      |> assign(:segments, layout.segments)
      |> assign(:lane_count, layout.lane_count)

    ~H"""
    <div class="flex">
      <div
        :if={Helpers.show_week_numbers?(@assigns_ref)}
        class="w-8 shrink-0 text-token-xs font-medium text-tymeslot-500 flex items-start justify-center pt-1 border-b border-r border-tymeslot-200"
      >
        {Helpers.week_number(List.first(@week_days))}
      </div>

      <div class="relative flex-1">
        <%!-- Day cells (define the row height) --%>
        <div class="grid grid-cols-7">
          <.month_cell
            :for={day <- @week_days}
            day={day}
            assigns_ref={@assigns_ref}
            lane_count={@lane_count}
            user_timezone={@user_timezone}
            myself={@myself}
          />
        </div>

        <%!-- Spanning bars overlaid across the week's columns. The layer ignores
              pointer events so empty band area still navigates the cell beneath;
              each bar re-enables them to open the event. --%>
        <div class="absolute inset-0 pointer-events-none">
          <div
            :for={seg <- @segments}
            class={"absolute px-1 flex items-center text-token-xs font-medium text-white truncate cursor-pointer pointer-events-auto #{bar_round_class(seg)} #{Helpers.color_for_event(@assigns_ref, seg.event)}"}
            style={bar_style(seg)}
            phx-click="show_event"
            phx-value-event-id={seg.event.id}
            phx-target={@myself}
            title={seg.event.summary || dgettext("dashboard_calendar", "(No title)")}
          >
            <img
              :if={Map.get(seg.event, :created_by_tymeslot)}
              src="/images/brand/logo.svg"
              alt=""
              class="inline-block w-3 h-3 opacity-70 mr-0.5 shrink-0"
            /><span class="truncate">{seg.event.summary ||
              dgettext("dashboard_calendar", "(No title)")}</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :day, :any, required: true
  attr :assigns_ref, :map, required: true
  attr :lane_count, :integer, required: true
  attr :user_timezone, :string, required: true
  attr :myself, :any, required: true

  defp month_cell(assigns) do
    chips = Helpers.chip_events(assigns.assigns_ref, assigns.day)

    today =
      DateTime.utc_now() |> DateTime.shift_zone!(assigns.user_timezone) |> DateTime.to_date()

    is_today = Date.compare(assigns.day, today) == :eq
    is_current_month = assigns.day.month == assigns.assigns_ref.date.month

    assigns =
      assigns
      |> assign(:chips, chips)
      |> assign(:is_today, is_today)
      |> assign(:is_current_month, is_current_month)
      |> assign(:locale, Gettext.get_locale(TymeslotWeb.Gettext))

    ~H"""
    <div
      class={"relative min-h-16 sm:min-h-24 border-b border-r border-tymeslot-200 p-1 cursor-pointer hover:bg-tymeslot-50 focus:outline-hidden focus:ring-2 focus:ring-turquoise-400 focus:ring-inset #{Helpers.month_cell_class(@day, @assigns_ref)}"}
      style={cell_padding_top(@lane_count)}
      phx-click="navigate_to_day"
      phx-value-date={Date.to_iso8601(@day)}
      phx-target={@myself}
      role="button"
      tabindex="0"
      aria-label={
        "#{LocaleFormat.format_weekday_name(Date.day_of_week(@day), @locale, :full)}, #{LocaleFormat.format_month_name(@day.month, @locale)} #{@day.day}" <>
          ", " <>
          dngettext(
            "dashboard_calendar",
            "%{count} event",
            "%{count} events",
            length(@chips),
            count: length(@chips)
          )
      }
    >
      <div class={"absolute top-1 left-1 text-token-sm font-semibold #{day_number_class(@is_today, @is_current_month)}"}>
        {@day.day}
      </div>

      <%!-- Desktop: up to 3 single-day event titles --%>
      <div class="hidden sm:block">
        <div
          :for={event <- Enum.take(@chips, 3)}
          class={"rounded px-1 text-token-xs font-medium text-white truncate mb-0.5 cursor-pointer #{Helpers.color_for_event(@assigns_ref, event)}"}
          phx-click="show_event"
          phx-value-event-id={event.id}
          phx-target={@myself}
        >
          <img
            :if={Map.get(event, :created_by_tymeslot)}
            src="/images/brand/logo.svg"
            alt=""
            class="inline-block w-3 h-3 opacity-60 mr-0.5 align-text-bottom"
          />{event.summary || dgettext("dashboard_calendar", "(No title)")}<span
            :if={EventBadges.guest_summary_for_event(@assigns_ref.guest_rsvp_summaries, event)}
            class={[
              "inline-block w-1.5 h-1.5 rounded-full ml-0.5 align-middle",
              EventBadges.guest_dot_tone(
                EventBadges.guest_summary_for_event(@assigns_ref.guest_rsvp_summaries, event)
              )
            ]}
            title={
              EventBadges.guest_badge_title(
                EventBadges.guest_summary_for_event(@assigns_ref.guest_rsvp_summaries, event)
              )
            }
          ></span>
        </div>
        <div :if={length(@chips) > 3} class="text-token-xs font-medium text-tymeslot-500 mt-0.5">
          {dngettext("dashboard_calendar", "+%{count} more", "+%{count} more", length(@chips) - 3,
            count: length(@chips) - 3
          )}
        </div>
      </div>

      <%!-- Mobile: first single-day title + coloured chip with count --%>
      <div class="sm:hidden flex flex-col gap-0.5">
        <div
          :if={List.first(@chips)}
          class={"rounded px-1 text-token-xs font-medium text-white truncate #{Helpers.color_for_event(@assigns_ref, List.first(@chips))}"}
        >
          {List.first(@chips).summary || dgettext("dashboard_calendar", "(No title)")}
        </div>
        <div
          :if={length(@chips) > 1}
          class="inline-flex items-center gap-0.5 text-token-2xs text-tymeslot-500 leading-none"
        >
          <span
            :for={event <- @chips |> Enum.drop(1) |> Enum.take(3)}
            class={"w-1.5 h-1.5 rounded-full #{Helpers.color_for_event(@assigns_ref, event)}"}
          ></span>
          <span :if={length(@chips) > 4} class="ml-0.5">+{length(@chips) - 4}</span>
        </div>
      </div>
    </div>
    """
  end

  # Reserve vertical room above the chips for the week's bar lanes.
  defp cell_padding_top(lane_count) do
    "padding-top: #{@band_top + lane_count * @lane_h}rem"
  end

  # Absolute placement of a spanning bar across the week's 7 columns.
  defp bar_style(seg) do
    left = Float.round(seg.start_col * 100 / 7, 4)
    width = Float.round((seg.end_col - seg.start_col + 1) * 100 / 7, 4)
    top = @band_top + seg.lane * @lane_h
    "left: #{left}%; width: #{width}%; top: #{top}rem; height: #{@bar_h}rem"
  end

  # Round only the ends that actually start/finish within this week; a bar that
  # continues into an adjacent week keeps a flat edge so it reads as continuous.
  defp bar_round_class(%{continues_left: false, continues_right: false}), do: "rounded"
  defp bar_round_class(%{continues_left: true, continues_right: false}), do: "rounded-r"
  defp bar_round_class(%{continues_left: false, continues_right: true}), do: "rounded-l"
  defp bar_round_class(%{continues_left: true, continues_right: true}), do: "rounded-none"

  defp day_number_class(true = _is_today, _is_current_month),
    do:
      "w-6 h-6 rounded-full bg-turquoise-600 text-white flex items-center justify-center text-center"

  defp day_number_class(_is_today, false = _is_current_month), do: "text-tymeslot-400"
  defp day_number_class(_is_today, _is_current_month), do: "text-tymeslot-800"
end
