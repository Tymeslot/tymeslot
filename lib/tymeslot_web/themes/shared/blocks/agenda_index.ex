defmodule TymeslotWeb.Themes.Shared.Blocks.AgendaIndex do
  @moduledoc """
  The week as an index: one row per day from today (in the visitor's `user_timezone`) with a free time, the
  date, then its times as plain text buttons, with previous and next week
  controls (`prev_week`, `next_week`, bounded as `WeekGrid`'s are by
  `CalendarNavigation`, carrying the markup contract's `data-intent="earlier"`
  and `"later"`). A time is one click for the date and the time
  together: a button for the slot fact (`data-fact="slot"`, `data-date`,
  `data-time`) sending `select_slot`.

  The times are the flow's week (`TymeslotWeb.Live.Scheduling.WeekSlots`);
  while `week_slots` is nil the block asks for it, sending `load_week` from
  `phx-mounted` and `phx-connected`. Clicks go to `target`.

  Classes: `agenda-index` (`--loading`), `__nav`, `__nav-button` (`--prev`,
  `--next`), `__nav-icon`, `__range`, `__rows`, `__row`, `__date`, `__times`,
  `__time` (`--selected`), `__empty`, `__loading`, `__error`. The shared
  structure is `scheduling/shared/blocks/agenda-index.css`, on tokens only.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Live.Scheduling.{CalendarHelpers, CalendarNavigation, WeekSlots}
  alias TymeslotWeb.Themes.Shared.Blocks.DayChips
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  attr :week_start, Date, required: true, doc: "the Monday of the week shown"
  attr :week_slots, :map, default: nil
  attr :loading, :boolean, default: false
  attr :error, :string, default: nil
  attr :selected_date, :string, default: nil
  attr :selected_time, :string, default: nil
  attr :user_timezone, :string, required: true
  attr :booking_window_days, :integer, default: nil
  attr :target, :any, required: true

  @spec agenda_index(map()) :: Phoenix.LiveView.Rendered.t()
  def agenda_index(assigns) do
    today = CalendarHelpers.visitor_today(assigns.user_timezone)

    assigns =
      assign(assigns,
        today: today,
        rows: WeekSlots.free_days(assigns.week_slots, today),
        state: WeekSlots.view_state(assigns.week_slots, assigns.loading, assigns.error),
        ask: is_nil(assigns.week_slots) && JS.push("load_week", target: assigns.target)
      )

    ~H"""
    <div
      class={["agenda-index", @loading && "agenda-index--loading"]}
      data-testid="agenda-index"
      phx-mounted={@ask}
      phx-connected={@ask}
    >
      <div class="agenda-index__nav">
        <button
          type="button"
          class="agenda-index__nav-button agenda-index__nav-button--prev"
          data-testid="agenda-index-prev"
          data-intent="earlier"
          phx-click="prev_week"
          phx-target={@target}
          disabled={CalendarNavigation.prev_week_disabled?(@week_start, @user_timezone)}
          aria-label={dgettext("booking", "Previous week")}
        >
          <.icon name="hero-chevron-left-mini" class="agenda-index__nav-icon" />
        </button>
        <p class="agenda-index__range">{LocalizationHelpers.get_week_display(@week_start)}</p>
        <button
          type="button"
          class="agenda-index__nav-button agenda-index__nav-button--next"
          data-testid="agenda-index-next"
          data-intent="later"
          phx-click="next_week"
          phx-target={@target}
          disabled={next_disabled?(@week_start, @user_timezone, @booking_window_days)}
          aria-label={dgettext("booking", "Next week")}
        >
          <.icon name="hero-chevron-right-mini" class="agenda-index__nav-icon" />
        </button>
      </div>
      <%= cond do %>
        <% @state == :error -> %>
          <p class="agenda-index__error" role="status">{@error}</p>
        <% @state == :loading -> %>
          <p class="agenda-index__loading" role="status">
            {dgettext("booking", "Loading available times...")}
          </p>
        <% @rows == [] -> %>
          <p class="agenda-index__empty">{dgettext("booking", "No times available")}</p>
        <% true -> %>
          <ol class="agenda-index__rows">
            <li :for={row <- @rows} class="agenda-index__row" data-date={row.iso}>
              <span class="agenda-index__date">
                <span aria-hidden="true">{DayChips.day_label(row.date, @today)}</span>
                <span class="sr-only">{LocalizationHelpers.format_full_date_label(row.date)}</span>
              </span>
              <ul class="agenda-index__times">
                <li :for={slot <- row.slots}>
                  <button
                    type="button"
                    class={[
                      "agenda-index__time",
                      (@selected_date == row.iso and @selected_time == slot) &&
                        "agenda-index__time--selected"
                    ]}
                    data-fact="slot"
                    data-date={row.iso}
                    data-time={slot}
                    phx-click="select_slot"
                    phx-value-date={row.iso}
                    phx-value-time={slot}
                    phx-target={@target}
                    disabled={@loading}
                    aria-pressed={to_string(@selected_date == row.iso and @selected_time == slot)}
                  >
                    {LocalizationHelpers.format_time_by_locale(CalendarHelpers.parse_slot_time(slot))}
                  </button>
                </li>
              </ul>
            </li>
          </ol>
      <% end %>
    </div>
    """
  end

  # No booking window known (no organiser resolved) bounds nothing.
  defp next_disabled?(week_start, timezone, days) when is_integer(days),
    do: CalendarNavigation.next_week_disabled?(week_start, timezone, days)

  defp next_disabled?(_week_start, _timezone, _days), do: false
end
