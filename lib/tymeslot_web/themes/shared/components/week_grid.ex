defmodule TymeslotWeb.Themes.Shared.Components.WeekGrid do
  @moduledoc """
  A week of free times on one screen, for a theme with a week view: one column
  per day from the week's Monday, each listing that day's times top to bottom,
  with previous and next week controls. One click on a time picks the day and
  the time together.

  The markup is fixed and carries `week-grid*` class names: `week-grid`
  (`--loading` while a fetch is on its way), `__nav`, `__nav-button`
  (`--prev`, `--next`), `__nav-icon`, `__range`, `__days`, `__day`
  (`--today`), `__day-heading`, `__day-name`, `__day-date`, `__slots`,
  `__slot` (`--selected`), `__empty`, `__loading`, `__error` and `__jump`. The shared
  structure is `scheduling/shared/components/week-grid.css`; a theme styles
  the classes through tokens and never restructures the DOM. `heading_tag` is
  an attribute because it is document semantics: the level of each day's
  heading in the page outline.

  A theme that needs markup of its own between the week navigation and the
  days (a day picker for a narrow screen, a notice about the week) passes it
  in the `:before_days` slot. It is rendered inside the grid, so it answers
  to the same `@container week-grid` queries as the days, in every state:
  while the week loads, after a failed fetch, and once it is loaded. A caller
  that passes none renders nothing there.

  Everything the grid shows comes from the flow's assigns
  (`TymeslotWeb.Live.Scheduling.WeekSlots`): `week_slots` is nil until the
  page asks for a week, then ISO date => that day's slots, and `loading` and
  `error` describe the fetch. Clicks go to `target` with the canonical
  events: `prev_week`, `next_week`, `select_slot` with `phx-value-date` and
  `phx-value-time`, and `first_available_week`, offered from any week but
  `landing_week`, the week the page landed the booker on
  (`CalendarHelpers.landing_week/1`). While `week_slots` is nil the grid asks for its week
  itself, sending `load_week` from `phx-mounted` (it appeared in the page) and
  `phx-connected` (every join of the LiveView, a rejoin after a lost
  connection included, which starts from no week), so a theme that renders it
  does nothing more to fetch one, and a theme that does not never fetches.

  Tests select times by `data-testid="week-slot"` with `data-date` and
  `data-time`, the controls by `week-grid-prev` and `week-grid-next`, the jump by
  `week-grid-first-available`. Each time also carries the markup contract's
  `data-fact="slot"` (its day and time in `data-date` and `data-time`) and the
  week buttons `data-intent="earlier"` and `data-intent="later"`
  (`THEME_DEVELOPMENT_GUIDE.md`, §"The markup contract").
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  use TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Live.Scheduling.{CalendarHelpers, CalendarNavigation, WeekSlots}
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  attr :week_start, Date, required: true, doc: "the Monday of the week shown"

  attr :week_slots, :map,
    default: nil,
    doc: "nil until a week is asked for, then ISO date => that day's slots"

  attr :loading, :boolean, default: false
  attr :error, :string, default: nil
  attr :selected_date, :string, default: nil
  attr :selected_time, :string, default: nil
  attr :today, Date, default: nil, doc: "the visitor's today, marked on its day"
  attr :user_timezone, :string, required: true
  attr :booking_window_days, :integer, default: nil

  attr :landing_week, Date,
    default: nil,
    doc: "the week the page landed the booker on (`CalendarHelpers.landing_week/1`)"

  attr :target, :any, required: true
  attr :heading_tag, :string, default: "h3", values: ~w(h2 h3 h4)

  slot :before_days,
    doc: "markup of the theme's own between the week navigation and the days, in every state"

  @spec week_grid(map()) :: Phoenix.LiveView.Rendered.t()
  def week_grid(assigns) do
    assigns =
      assign(assigns,
        days: days(assigns.week_start, assigns.week_slots, assigns.today),
        state: state(assigns),
        ask: is_nil(assigns.week_slots) && JS.push("load_week", target: assigns.target)
      )

    ~H"""
    <div
      class={["week-grid", @loading && "week-grid--loading"]}
      data-testid="week-grid"
      data-week-start={Date.to_iso8601(@week_start)}
      phx-mounted={@ask}
      phx-connected={@ask}
    >
      <div class="week-grid__nav">
        <button
          type="button"
          class="week-grid__nav-button week-grid__nav-button--prev"
          data-testid="week-grid-prev"
          data-intent="earlier"
          phx-click="prev_week"
          phx-target={@target}
          disabled={CalendarNavigation.prev_week_disabled?(@week_start, @user_timezone)}
          aria-label={dgettext("booking", "Previous week")}
        >
          <.icon name="hero-chevron-left-mini" class="week-grid__nav-icon" />
        </button>
        <p class="week-grid__range">{LocalizationHelpers.get_week_display(@week_start)}</p>
        <button
          type="button"
          class="week-grid__nav-button week-grid__nav-button--next"
          data-testid="week-grid-next"
          data-intent="later"
          phx-click="next_week"
          phx-target={@target}
          disabled={next_disabled?(@week_start, @user_timezone, @booking_window_days)}
          aria-label={dgettext("booking", "Next week")}
        >
          <.icon name="hero-chevron-right-mini" class="week-grid__nav-icon" />
        </button>
        <button
          :if={@landing_week && @landing_week != @week_start}
          type="button"
          class="week-grid__jump"
          data-testid="week-grid-first-available"
          phx-click="first_available_week"
          phx-target={@target}
        >
          {dgettext("booking", "Jump to first available")}
        </button>
      </div>
      {render_slot(@before_days)}
      <div class="sr-only" role="status" aria-live="polite" aria-atomic="true">
        {status_text(@state, @error)}
      </div>
      <%= case @state do %>
        <% :error -> %>
          <div class="week-grid__error">{@error}</div>
        <% :loading -> %>
          <div class="week-grid__loading">
            <span>{dgettext("booking", "Loading available times...")}</span>
          </div>
        <% :loaded -> %>
          <div class="week-grid__days booker-scroll">
            <section
              :for={day <- @days}
              class={["week-grid__day", day.today && "week-grid__day--today"]}
              data-date={day.iso}
            >
              <.dynamic_tag tag_name={@heading_tag} class="week-grid__day-heading">
                <span class="sr-only">{LocalizationHelpers.format_full_date_label(day.date)}</span>
                <span class="week-grid__day-name" aria-hidden="true">
                  {LocalizationHelpers.day_name_short(Date.day_of_week(day.date))}
                </span>
                <span class="week-grid__day-date" aria-hidden="true">{day.date.day}</span>
              </.dynamic_tag>
              <ul :if={day.slots != []} class="week-grid__slots">
                <li :for={slot <- day.slots}>
                  <button
                    type="button"
                    class={[
                      "week-grid__slot",
                      selected?(@selected_date, @selected_time, day.iso, slot) &&
                        "week-grid__slot--selected"
                    ]}
                    data-testid="week-slot"
                    data-fact="slot"
                    data-date={day.iso}
                    data-time={slot}
                    phx-click="select_slot"
                    phx-value-date={day.iso}
                    phx-value-time={slot}
                    phx-target={@target}
                    disabled={@loading}
                    aria-pressed={to_string(selected?(@selected_date, @selected_time, day.iso, slot))}
                  >
                    {LocalizationHelpers.format_time_by_locale(CalendarHelpers.parse_slot_time(slot))}
                  </button>
                </li>
              </ul>
              <p :if={day.slots == []} class="week-grid__empty">
                {dgettext("booking", "No times available")}
              </p>
            </section>
          </div>
      <% end %>
    </div>
    """
  end

  defp days(week_start, week_slots, today) do
    for offset <- 0..6 do
      date = Date.add(week_start, offset)
      iso = Date.to_iso8601(date)

      %{
        date: date,
        iso: iso,
        today: date == today,
        slots: WeekSlots.times(Map.get(week_slots || %{}, iso, []))
      }
    end
  end

  # A failed fetch wins; then no week yet, or another week still on its way
  # (its slots emptied); a refetch of the week on screen keeps it showing.
  defp state(%{error: error}) when is_binary(error), do: :error
  defp state(%{week_slots: nil}), do: :loading
  defp state(%{loading: true, week_slots: slots}) when map_size(slots) == 0, do: :loading
  defp state(_assigns), do: :loaded

  defp status_text(:error, error), do: error
  defp status_text(:loading, _error), do: dgettext("booking", "Loading available times...")
  defp status_text(:loaded, _error), do: dgettext("booking", "Available Times")

  defp selected?(selected_date, selected_time, date, slot),
    do: selected_date == date and selected_time == slot

  # No booking window known (no organiser resolved) bounds nothing.
  defp next_disabled?(week_start, timezone, days) when is_integer(days),
    do: CalendarNavigation.next_week_disabled?(week_start, timezone, days)

  defp next_disabled?(_week_start, _timezone, _days), do: false
end
