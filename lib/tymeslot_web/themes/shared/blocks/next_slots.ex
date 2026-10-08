defmodule TymeslotWeb.Themes.Shared.Blocks.NextSlots do
  @moduledoc """
  The soonest free times, for a journey that starts from time: the first
  `days` days from today (in the visitor's `user_timezone`) with a free time, each a heading ("Today",
  "Tomorrow", "Fri 12") and its times as large buttons, then "More times",
  which shows the rest of the week the flow has loaded. A time is one click
  for the date and the time together: a button for the slot fact
  (`data-fact="slot"`, `data-date`, `data-time`) sending `select_slot`.

  The times come from the flow's week (`TymeslotWeb.Live.Scheduling.WeekSlots`,
  `Offer.slots_for_range/4`). While `week_slots` is nil the block asks for it,
  sending `load_week` from `phx-mounted` and `phx-connected`, as `WeekGrid`
  does. The page lands the week on the visitor's first free day
  (`NextAvailable`), so the soonest days are in it; when the week holds no
  free time from today on, the block says so. Either way it offers the next
  week after the last day shown (`next_week`, with the markup contract's
  `data-intent="later"`), so a visitor whose week still has free times can
  reach the next one. "More times" needs no round trip: the further days are in
  the page, `hidden`, and the control (`aria-expanded`, `aria-controls` the extra days) reveals
  them, hides itself and moves the focus to the first revealed day's heading, with client commands that survive the
  page's updates. `id` scopes those commands. Clicks go to `target`.

  Classes: `next-slots` (`--loading`), `__days`, `__day` (`--extra`),
  `__day-heading`, `__day-label`, `__slots`, `__slot` (`--selected`),
  `__more`, `__empty`, `__next-week`, `__loading`, `__error`. The shared
  structure is `scheduling/shared/blocks/next-slots.css`, on tokens only.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Live.Scheduling.{CalendarHelpers, WeekSlots}
  alias TymeslotWeb.Themes.Shared.Blocks.DayChips
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  attr :id, :string, required: true, doc: "the element the More control's commands are scoped to"

  attr :week_slots, :map,
    default: nil,
    doc: "nil until a week is asked for, then ISO date => that day's slots"

  attr :loading, :boolean, default: false
  attr :error, :string, default: nil

  attr :user_timezone, :string,
    required: true,
    doc: "the visitor's timezone; \"Today\" is the date it is now there"

  attr :selected_date, :string, default: nil
  attr :selected_time, :string, default: nil
  attr :days, :integer, default: 3, doc: "how many days with free times show before More"
  attr :target, :any, required: true
  attr :heading_tag, :string, default: "h3", values: ~w(h2 h3 h4)

  @spec next_slots(map()) :: Phoenix.LiveView.Rendered.t()
  def next_slots(assigns) do
    today = CalendarHelpers.visitor_today(assigns.user_timezone)

    {first, extra} =
      assigns.week_slots |> WeekSlots.free_days(today) |> Enum.split(assigns.days)

    assigns =
      assign(assigns,
        today: today,
        first: first,
        extra: extra,
        state: WeekSlots.view_state(assigns.week_slots, assigns.loading, assigns.error),
        ask: is_nil(assigns.week_slots) && JS.push("load_week", target: assigns.target)
      )

    ~H"""
    <div
      id={@id}
      class={["next-slots", @loading && "next-slots--loading"]}
      data-testid="next-slots"
      phx-mounted={@ask}
      phx-connected={@ask}
    >
      <div class="sr-only" role="status" aria-live="polite" aria-atomic="true">
        {status_text(@state, @error)}
      </div>
      <%= case @state do %>
        <% :error -> %>
          <p class="next-slots__error">{@error}</p>
        <% :loading -> %>
          <p class="next-slots__loading">{dgettext("booking", "Loading available times...")}</p>
        <% :loaded -> %>
          <%= if @first == [] do %>
            <div class="next-slots__empty">
              <p>{dgettext("booking", "No times available")}</p>
              <.next_week target={@target} />
            </div>
          <% else %>
            <div class="next-slots__days">
              <.day
                :for={day <- @first ++ @extra}
                id={@id}
                day={day}
                extra={day in @extra}
                first_extra={@extra != [] and day == hd(@extra)}
                today={@today}
                selected_date={@selected_date}
                selected_time={@selected_time}
                loading={@loading}
                heading_tag={@heading_tag}
                target={@target}
              />
            </div>
            <button
              :if={@extra != []}
              type="button"
              class="next-slots__more"
              data-testid="next-slots-more"
              aria-expanded="false"
              aria-controls={Enum.map_join(@extra, " ", &day_id(@id, &1))}
              phx-click={
                JS.remove_attribute("hidden", to: "##{@id} .next-slots__day--extra")
                |> JS.hide()
                |> JS.focus(to: "##{more_start_id(@id)}")
              }
            >
              {dgettext("booking", "More times")}
            </button>
            <.next_week target={@target} />
          <% end %>
      <% end %>
    </div>
    """
  end

  attr :target, :any, required: true

  defp next_week(assigns) do
    ~H"""
    <button
      type="button"
      class="next-slots__next-week"
      data-testid="next-slots-next-week"
      data-intent="later"
      phx-click="next_week"
      phx-target={@target}
    >
      {dgettext("booking", "Next week")}
    </button>
    """
  end

  attr :id, :string, required: true
  attr :day, :map, required: true
  attr :extra, :boolean, required: true
  attr :first_extra, :boolean, required: true
  attr :today, Date, required: true
  attr :selected_date, :string, default: nil
  attr :selected_time, :string, default: nil
  attr :loading, :boolean, required: true
  attr :heading_tag, :string, required: true
  attr :target, :any, required: true

  defp day(assigns) do
    ~H"""
    <section
      id={day_id(@id, @day)}
      class={["next-slots__day", @extra && "next-slots__day--extra"]}
      data-date={@day.iso}
      hidden={@extra}
    >
      <.dynamic_tag
        tag_name={@heading_tag}
        id={@first_extra && more_start_id(@id)}
        class="next-slots__day-heading"
        tabindex="-1"
      >
        <span class="next-slots__day-label" aria-hidden="true">{DayChips.day_label(@day.date, @today)}</span>
        <span class="sr-only">{LocalizationHelpers.format_full_date_label(@day.date)}</span>
      </.dynamic_tag>
      <ul class="next-slots__slots">
        <li :for={slot <- @day.slots}>
          <button
            type="button"
            class={[
              "next-slots__slot",
              selected?(@selected_date, @selected_time, @day.iso, slot) &&
                "next-slots__slot--selected"
            ]}
            data-fact="slot"
            data-date={@day.iso}
            data-time={slot}
            phx-click="select_slot"
            phx-value-date={@day.iso}
            phx-value-time={slot}
            phx-target={@target}
            disabled={@loading}
            aria-pressed={to_string(selected?(@selected_date, @selected_time, @day.iso, slot))}
          >
            {LocalizationHelpers.format_time_by_locale(CalendarHelpers.parse_slot_time(slot))}
          </button>
        </li>
      </ul>
    </section>
    """
  end

  defp day_id(id, day), do: "#{id}-day-#{day.iso}"

  # The heading More times moves the focus to: the first day it reveals.
  defp more_start_id(id), do: "#{id}-more-start"

  defp status_text(:error, error), do: error
  defp status_text(:loading, _error), do: dgettext("booking", "Loading available times...")
  defp status_text(:loaded, _error), do: dgettext("booking", "Available Times")

  defp selected?(selected_date, selected_time, date, slot),
    do: selected_date == date and selected_time == slot
end
