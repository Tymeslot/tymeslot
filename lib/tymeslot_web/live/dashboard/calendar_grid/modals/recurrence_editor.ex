defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.RecurrenceEditor do
  @moduledoc """
  Reusable "Repeat" control for the calendar create/detail modals.

  Builds every pattern `Tymeslot.Integrations.Calendar.Recurrence.Pattern`
  covers: a frequency (Does not repeat / Daily / Weekly / Monthly / Yearly),
  an interval ("every N"), weekday toggles for a weekly pattern, a choice of
  day for a monthly or yearly one (on the start's day, or on a position the
  start is, such as the second Tuesday or the last weekday), and an end
  (never / after N occurrences / on a date). A summary of the current rule
  sits beneath the controls.

  The patterns are anchored to the event's start (`start`): a weekly pattern
  always includes the start's weekday, a monthly or yearly one offers only
  the positions the start is, and a hint says to move the event to repeat on
  another day.

  An end picked before its number or date is given starts from a default
  (`Pattern.default_count/0`, `Pattern.default_until/2`), since its field
  appears only once it is picked. The number fields send on blur, so a
  series is not rewritten at every keystroke.

  A stored rule no pattern matches (`Pattern.read/2` answers `:custom`) is
  shown as a summary with a "Replace repeat rule" action and no controls, so
  it is never rewritten by accident. The action reveals the controls on the
  client, prefilled from the rule's frequency, interval and end; nothing is
  written until one of them changes.

  Every control change dispatches `change_event` back to the owning
  LiveComponent via `phx-target`, carrying the raw form fields (`freq`,
  `interval`, `by_day[]`, `on`, `end_type`, `count`, `until`). The owner
  composes the rule from them (`Shared.compose_recurrence_rule/2`). An
  owner that stages the rule rather than writing it at once (an existing
  event's details, `RecurrenceEdit`) passes `pending` while one is staged,
  and the editor offers "Save repeat" (`save_event`) and "Discard changes"
  (`discard_event`). `notice` says why the calendar would refuse the rule.

  `timezone` reads a timed rule's `UNTIL`, an instant, as the date the
  organiser sees.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.Integrations.Calendar.Recurrence.Pattern
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.RecurrenceSummary
  alias TymeslotWeb.Helpers.LocaleFormat

  attr :recurrence_rule, :string, default: nil
  attr :timezone, :string, default: nil

  attr :start, :any,
    required: true,
    doc: "the event's start: a `Date` for an all-day event, else a `DateTime` in `timezone`"

  attr :myself, :any, required: true
  attr :change_event, :string, required: true

  attr :pending, :boolean,
    default: false,
    doc: "whether the rule shown is staged and not yet saved, which offers to save or discard it"

  attr :save_event, :string, default: nil
  attr :discard_event, :string, default: nil

  attr :save_blocked, :boolean,
    default: false,
    doc: "whether the staged rule cannot be saved as it is (`notice` says why)"

  attr :notice, :string,
    default: nil,
    doc: "why the calendar would refuse the rule shown, if it would"

  @spec recurrence_editor(map()) :: Phoenix.LiveView.Rendered.t()
  def recurrence_editor(assigns) do
    start_date = start_date(assigns.start)
    read = Pattern.read(assigns.recurrence_rule, assigns.start)

    pattern =
      case read do
        {:ok, pattern} -> pattern || %{}
        :custom -> Pattern.closest(assigns.recurrence_rule, assigns.start)
      end

    freq = pattern[:freq]

    assigns =
      assign(assigns,
        custom: read == :custom,
        freq: freq,
        interval: pattern[:interval] || 1,
        by_day: pattern[:by_day] || [start_weekday(start_date)],
        start_weekday: start_weekday(start_date),
        on: Map.get(pattern, :on, :day),
        on_options: on_options(freq, start_date),
        end_type: end_type(pattern),
        count: pattern[:count] || Pattern.default_count(),
        until: until_value(pattern[:until]),
        weekdays: weekdays(),
        freq_options: freq_options(),
        summary:
          RecurrenceSummary.summary(
            if(read == :custom, do: :custom, else: elem(read, 1)),
            start_date
          ),
        form_id: "recurrence-editor-form-#{assigns.change_event}",
        custom_id: "recurrence-custom-#{assigns.change_event}"
      )

    ~H"""
    <.detail_line
      variant={:compact}
      icon="hero-arrow-path"
      label={dgettext("dashboard_calendar_repeat", "Repeat")}
    >
      <div :if={@custom} id={@custom_id} class="space-y-2">
        <p class="text-token-sm text-tymeslot-600 leading-snug">{@summary}</p>
        <.action_button
          variant={:secondary}
          size={:sm}
          phx-click={JS.hide(to: "##{@custom_id}") |> JS.show(to: "##{@form_id}")}
        >
          {dgettext("dashboard_calendar_repeat", "Replace repeat rule")}
        </.action_button>
      </div>

      <form
        id={@form_id}
        phx-change={@change_event}
        phx-target={@myself}
        class={["space-y-2", @custom && "hidden"]}
      >
        <select
          name="freq"
          aria-label={dgettext("dashboard_calendar_repeat", "Repeat")}
          class="w-full rounded-token-md border-tymeslot-300 text-token-xs text-tymeslot-700 focus:border-turquoise-500 focus:ring-turquoise-500 py-1"
        >
          <option
            :for={{value, label} <- @freq_options}
            value={value}
            selected={to_string(@freq) == value}
          >
            {label}
          </option>
        </select>

        <div :if={@freq != nil} class="space-y-2 pl-0.5">
          <div class="flex items-center gap-2">
            <label class="text-token-xs text-tymeslot-600">{dgettext(
              "dashboard_calendar_repeat",
              "Every"
            )}</label>
            <input
              type="number"
              name="interval"
              min="1"
              max={Pattern.max_number()}
              value={@interval}
              phx-debounce="blur"
              class="w-16 rounded-token-md border-tymeslot-300 text-token-xs text-tymeslot-700 focus:border-turquoise-500 focus:ring-turquoise-500 py-1"
            />
            <span class="text-token-xs text-tymeslot-600">{interval_unit(@freq, @interval)}</span>
          </div>

          <div :if={@freq == :weekly} class="flex flex-wrap gap-1">
            <%!-- The start's weekday is always one of a weekly pattern's
                 days (`Pattern`), so it cannot be unticked. It is sent
                 beside its disabled box as "start", the start's weekday
                 whichever day that is when the rule is composed, so a
                 start that moves takes it along. --%>
            <input type="hidden" name="by_day[]" value="start" />
            <label
              :for={{day, label} <- @weekdays}
              class={[
                "px-2 py-1 rounded-token-md border text-token-xs transition-all select-none",
                cond do
                  day == @start_weekday ->
                    "border-turquoise-400 bg-turquoise-50 text-turquoise-800 font-semibold cursor-not-allowed"

                  day in @by_day ->
                    "border-turquoise-400 bg-turquoise-50 text-turquoise-800 font-semibold cursor-pointer"

                  true ->
                    "border-tymeslot-200 text-tymeslot-600 hover:border-tymeslot-300 hover:bg-tymeslot-50 cursor-pointer"
                end
              ]}
            >
              <input
                type="checkbox"
                name="by_day[]"
                value={day}
                checked={day in @by_day or day == @start_weekday}
                disabled={day == @start_weekday}
                class="sr-only"
              />
              {label}
            </label>
          </div>

          <div :if={@freq in [:monthly, :yearly]}>
            <select
              name="on"
              aria-label={dgettext("dashboard_calendar_repeat", "Repeats on")}
              class="w-full rounded-token-md border-tymeslot-300 text-token-xs text-tymeslot-700 focus:border-turquoise-500 focus:ring-turquoise-500 py-1"
            >
              <option
                :for={{value, label, on} <- @on_options}
                value={value}
                selected={on == @on}
              >
                {label}
              </option>
            </select>
          </div>

          <p :if={@freq in [:weekly, :monthly, :yearly]} class="text-token-xs text-tymeslot-400">
            {dgettext(
              "dashboard_calendar_repeat",
              "To repeat on another day, move the event to that day."
            )}
          </p>

          <div class="flex flex-wrap items-center gap-2">
            <select
              name="end_type"
              class="rounded-token-md border-tymeslot-300 text-token-xs text-tymeslot-700 focus:border-turquoise-500 focus:ring-turquoise-500 py-1"
            >
              <option value="never" selected={@end_type == "never"}>
                {dgettext("dashboard_calendar_repeat", "Never ends")}
              </option>
              <option value="count" selected={@end_type == "count"}>
                {dgettext("dashboard_calendar_repeat", "After")}
              </option>
              <option value="until" selected={@end_type == "until"}>
                {dgettext("dashboard_calendar_repeat", "On date")}
              </option>
            </select>

            <div :if={@end_type == "count"} class="flex items-center gap-1.5">
              <input
                type="number"
                name="count"
                min="1"
                max={Pattern.max_number()}
                value={@count}
                phx-debounce="blur"
                class="w-16 rounded-token-md border-tymeslot-300 text-token-xs text-tymeslot-700 focus:border-turquoise-500 focus:ring-turquoise-500 py-1"
              />
              <span class="text-token-xs text-tymeslot-600">{dngettext(
                "dashboard_calendar_repeat",
                "occurrence",
                "occurrences",
                @count
              )}</span>
            </div>

            <input
              :if={@end_type == "until"}
              type="date"
              name="until"
              value={@until}
              class="rounded-token-md border-tymeslot-300 text-token-xs text-tymeslot-700 focus:border-turquoise-500 focus:ring-turquoise-500 py-1"
            />
          </div>
        </div>
      </form>

      <p :if={@summary != nil and not @custom} class="text-token-xs text-tymeslot-400 mt-1.5">
        {@summary}
      </p>

      <p :if={@notice} class="text-token-xs text-red-700 mt-1.5" role="alert">{@notice}</p>

      <div :if={@pending} class="flex flex-wrap gap-2 mt-2">
        <.action_button
          size={:sm}
          phx-click={@save_event}
          phx-target={@myself}
          disabled={@save_blocked}
        >
          {dgettext("dashboard_calendar_repeat", "Save repeat")}
        </.action_button>
        <.action_button
          variant={:secondary}
          size={:sm}
          phx-click={@discard_event}
          phx-target={@myself}
        >
          {dgettext("dashboard_calendar_repeat", "Discard changes")}
        </.action_button>
      </div>
    </.detail_line>
    """
  end

  @doc """
  The summary of `rule` for an event starting at `start` (see the `start`
  attr), as the editor shows it; nil for no rule.
  """
  @spec summary(String.t() | nil, Date.t() | DateTime.t()) :: String.t() | nil
  def summary(rule, start) do
    read =
      case Pattern.read(rule, start) do
        {:ok, pattern} -> pattern
        :custom -> :custom
      end

    RecurrenceSummary.summary(read, start_date(start))
  end

  # The day choices a monthly or yearly pattern offers for this start, each
  # as `{field value, label, on}`.
  defp on_options(freq, start_date) when freq in [:monthly, :yearly] do
    for on <- Pattern.choices(start_date),
        do: {on_value(on), RecurrenceSummary.on_phrase(on, freq, start_date), on}
  end

  defp on_options(_freq, _start_date), do: []

  defp on_value(:day), do: "day"
  defp on_value({ordinal, kind}), do: "#{ordinal}:#{kind}"

  defp start_date(%DateTime{} = start), do: DateTime.to_date(start)
  defp start_date(%Date{} = start), do: start

  defp start_weekday(date), do: Enum.at(~w(mo tu we th fr sa su)a, Date.day_of_week(date) - 1)

  defp end_type(%{count: count}) when is_integer(count), do: "count"
  defp end_type(%{until: %Date{}}), do: "until"
  defp end_type(_pattern), do: "never"

  defp until_value(%Date{} = date), do: Date.to_iso8601(date)
  defp until_value(_other), do: ""

  # "Every 2 weeks": the unit agrees with the interval in front of it.
  defp interval_unit(:daily, n), do: dngettext("dashboard_calendar_repeat", "day", "days", n)
  defp interval_unit(:weekly, n), do: dngettext("dashboard_calendar_repeat", "week", "weeks", n)

  defp interval_unit(:monthly, n),
    do: dngettext("dashboard_calendar_repeat", "month", "months", n)

  defp interval_unit(:yearly, n), do: dngettext("dashboard_calendar_repeat", "year", "years", n)

  # A day's chip stands on its own, so it starts with a capital even in
  # the languages that write weekdays lowercase mid-sentence.
  defp weekdays do
    for day <- ~w(mo tu we th fr sa su)a,
        do: {day, LocaleFormat.capitalize_first(RecurrenceSummary.weekday_label(day))}
  end

  defp freq_options do
    [
      {"", dgettext("dashboard_calendar_repeat", "Does not repeat")},
      {"daily", dgettext("dashboard_calendar_repeat", "Daily")},
      {"weekly", dgettext("dashboard_calendar_repeat", "Weekly")},
      {"monthly", dgettext("dashboard_calendar_repeat", "Monthly")},
      {"yearly", dgettext("dashboard_calendar_repeat", "Yearly")}
    ]
  end
end
