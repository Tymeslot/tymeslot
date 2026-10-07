defmodule TymeslotWeb.Themes.Shared.Components.SlotList do
  @moduledoc """
  The schedule step's time-slot panel, shared by every theme: the heading, the
  screen-reader status line, the slots grouped by part of the day (and, for a
  meeting type offering starts on a grid finer than its duration, by hour
  behind a toggle, see `SlotGrouping`), and the prompt, loading, error and
  fully-booked states.

  The markup is fixed and carries `slot-list__*` class names; each theme
  styles them in its own CSS and never restructures the DOM. Two choices are
  attributes because they are document semantics rather than looks:
  `heading_tag`, the panel heading's level in the page outline, and
  `period_tag`, whether "Morning" and "Afternoon" are headings. The loading,
  error and fully-booked states render plain default markup; a theme that
  shows them with core components passes its own through the `:loading`,
  `:error` (receives the message) and `:empty` slots.

  Clicks go to `target`: `select_time` with `phx-value-time`, and
  `toggle_hour` with `phx-value-hour`. The `AutoScrollToSlots` hook in
  `assets/js/utility_hooks.js` relies on `#slots-container`,
  `.slot-list__heading` and `[data-slots-loaded]`; change them together.
  Each time button carries the markup contract's `data-fact="time"`, its
  `data-value` the value `select_time` sends.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.MeetingUtils
  alias TymeslotWeb.Live.Scheduling.CalendarHelpers
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.SlotGrouping

  attr :selected_date, :string, default: nil
  attr :selected_time, :string, default: nil
  attr :available_slots, :list, default: []
  attr :loading_slots, :boolean, default: false
  attr :calendar_error, :string, default: nil
  attr :slot_interval_minutes, :integer, default: nil
  attr :duration_minutes, :integer, default: nil

  attr :expanded_hour, :any,
    default: nil,
    doc: "the hour the visitor opened (0..23), `:none` after a deliberate collapse, or nil"

  attr :target, :any, required: true
  attr :heading_tag, :string, default: "h2", values: ~w(h2 h3)
  attr :period_tag, :string, default: "div", values: ~w(div h3 h4)

  slot :loading, doc: "replaces the default loading markup"
  slot :error, doc: "replaces the default error markup; receives the error message"
  slot :empty, doc: "replaces the default fully-booked markup"

  @spec slot_list(map()) :: Phoenix.LiveView.Rendered.t()
  def slot_list(assigns) do
    slots = MeetingUtils.normalize_slot_list(assigns.available_slots)
    grouping = SlotGrouping.group(slots, assigns.slot_interval_minutes, assigns.duration_minutes)

    assigns =
      assign(assigns,
        slots: slots,
        grouping: grouping,
        open_hour: SlotGrouping.effective_expanded_hour(assigns.expanded_hour, grouping),
        selected_hour: SlotGrouping.selected_hour(grouping, assigns.selected_time)
      )

    ~H"""
    <div class="slot-list" id="slots-container" phx-hook="AutoScrollToSlots">
      <.dynamic_tag tag_name={@heading_tag} class="slot-list__heading" tabindex="-1">
        {dgettext("booking", "Available Times")}
      </.dynamic_tag>
      <%!-- Concise, screen-reader-only announcement of the slot-loading state
            so keyboard/AT users hear the result of picking a date. --%>
      <div class="sr-only" role="status" aria-live="polite" aria-atomic="true">
        {status_text(@selected_date, @loading_slots, @calendar_error, @slots)}
      </div>
      <div class="slot-list__body booker-scroll">
        <%= cond do %>
          <% is_nil(@selected_date) -> %>
            <div class="slot-list__prompt">
              <p>{dgettext("booking", "Please select a date to see available times")}</p>
            </div>
          <% @loading_slots -> %>
            <%= if @loading == [] do %>
              <div class="slot-list__loading">
                <span>{dgettext("booking", "Loading available times...")}</span>
              </div>
            <% else %>
              {render_slot(@loading)}
            <% end %>
          <% @calendar_error -> %>
            <%= if @error == [] do %>
              <div class="slot-list__error">{@calendar_error}</div>
            <% else %>
              {render_slot(@error, @calendar_error)}
            <% end %>
          <% @slots == [] -> %>
            <%= if @empty == [] do %>
              <div class="slot-list__empty">
                <p>{dgettext("booking", "This date is fully booked")}</p>
                <p>{dgettext("booking", "Please select another date")}</p>
              </div>
            <% else %>
              {render_slot(@empty)}
            <% end %>
          <% true -> %>
            <div class="slot-list__groups" data-slots-loaded={@selected_date}>
              <%= case @grouping do %>
                <% {:flat, periods} -> %>
                  <%= for {period, period_slots} <- periods, period_slots != [] do %>
                    <div class="slot-list__period">
                      <.dynamic_tag tag_name={@period_tag} class="slot-list__period-label">
                        {period}
                      </.dynamic_tag>
                      <div class="slot-list__grid">
                        <.slot_button
                          :for={slot_value <- period_slots}
                          slot_value={slot_value}
                          selected={@selected_time == slot_value}
                          target={@target}
                        />
                      </div>
                    </div>
                  <% end %>
                <% {:hours, periods} -> %>
                  <%= for {period, hours} <- periods, hours != [] do %>
                    <div class="slot-list__period">
                      <.dynamic_tag tag_name={@period_tag} class="slot-list__period-label">
                        {period}
                      </.dynamic_tag>
                      <div class="slot-list__grid">
                        <button
                          :for={{hour, hour_slots} <- hours}
                          type="button"
                          class={[
                            "slot-list__slot slot-list__slot--hour",
                            @open_hour == hour && "slot-list__slot--expanded",
                            @open_hour != hour && @selected_hour == hour &&
                              "slot-list__slot--selected"
                          ]}
                          data-testid="slot-hour"
                          phx-click="toggle_hour"
                          phx-target={@target}
                          phx-value-hour={hour}
                          aria-expanded={to_string(@open_hour == hour)}
                          aria-controls={@open_hour == hour && "slot-hour-panel-#{hour}"}
                          aria-label={hour_label_for_screen_readers(hour, length(hour_slots))}
                        >
                          <span class="slot-list__hour-label" aria-hidden="true">
                            {SlotGrouping.hour_label(hour)}
                          </span>
                          <span class="slot-list__hour-count" aria-hidden="true">
                            {length(hour_slots)}
                          </span>
                        </button>
                      </div>
                      <%= for {hour, hour_slots} <- hours, hour == @open_hour do %>
                        <div
                          class="slot-list__grid slot-list__grid--minutes"
                          id={"slot-hour-panel-#{hour}"}
                          role="group"
                          aria-label={SlotGrouping.hour_label(hour)}
                        >
                          <.slot_button
                            :for={slot_value <- hour_slots}
                            slot_value={slot_value}
                            selected={@selected_time == slot_value}
                            target={@target}
                          />
                        </div>
                      <% end %>
                    </div>
                  <% end %>
              <% end %>
            </div>
        <% end %>
      </div>
    </div>
    """
  end

  # One definition of the slot button, so the flat grid and the minutes nested
  # under an expanded hour cannot drift apart in markup.
  attr :slot_value, :string, required: true
  attr :selected, :boolean, default: false
  attr :target, :any, required: true

  defp slot_button(assigns) do
    ~H"""
    <button
      type="button"
      class={["slot-list__slot", @selected && "slot-list__slot--selected"]}
      data-testid="time-slot"
      data-time={@slot_value}
      data-fact="time"
      data-value={@slot_value}
      phx-click="select_time"
      phx-value-time={@slot_value}
      phx-target={@target}
    >
      {LocalizationHelpers.format_time_by_locale(CalendarHelpers.parse_slot_time(@slot_value))}
    </button>
    """
  end

  # The status line's precedence: no date, then loading, then an error, then
  # what the day holds. Stale slots left over from the previous date must not
  # be announced while the new ones load.
  defp status_text(selected_date, loading_slots, calendar_error, slots) do
    cond do
      is_nil(selected_date) -> dgettext("booking", "Please select a date to see available times")
      loading_slots -> dgettext("booking", "Loading available times...")
      calendar_error -> calendar_error
      slots != [] -> dgettext("booking", "Available Times")
      true -> dgettext("booking", "This date is fully booked")
    end
  end

  defp hour_label_for_screen_readers(hour, count) do
    dngettext(
      "booking",
      "%{hour}, %{count} available time",
      "%{hour}, %{count} available times",
      count,
      hour: SlotGrouping.hour_label(hour),
      count: count
    )
  end
end
