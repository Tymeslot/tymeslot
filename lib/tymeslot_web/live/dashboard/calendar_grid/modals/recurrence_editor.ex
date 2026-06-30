defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.RecurrenceEditor do
  @moduledoc """
  Reusable "Repeat" control for the calendar create/detail modals.

  Renders a frequency selector (Does not repeat / Daily / Weekly / Monthly /
  Yearly). Choosing a repeating frequency reveals the recurrence detail row:
  an interval ("every N"), weekday toggles (weekly only), and an end condition
  (never / after N occurrences / on a date). A human-readable summary of the
  current rule is shown beneath the controls.

  Every control change dispatches `change_event` back to the owning
  LiveComponent via `phx-target`, carrying the raw form fields (`freq`,
  `interval`, `by_day[]`, `end_type`, `count`, `until`). The owner composes the
  canonical RRULE string from those fields via
  `Tymeslot.Integrations.Calendar.Recurrence.RRule.build/1` and threads it
  through its state — keeping this component stateless and free of RRULE logic.

  `recurrence_rule` is the current canonical RRULE string (or nil); it is parsed
  only to seed the control values for display.
  """

  use TymeslotWeb, :html

  alias Tymeslot.Integrations.Calendar.Recurrence.RRule

  @weekdays [
    {:mo, "Mon"},
    {:tu, "Tue"},
    {:we, "Wed"},
    {:th, "Thu"},
    {:fr, "Fri"},
    {:sa, "Sat"},
    {:su, "Sun"}
  ]

  @freq_options [
    {"", "Does not repeat"},
    {"daily", "Daily"},
    {"weekly", "Weekly"},
    {"monthly", "Monthly"},
    {"yearly", "Yearly"}
  ]

  attr :recurrence_rule, :string, default: nil
  attr :myself, :any, required: true
  attr :change_event, :string, required: true

  @spec recurrence_editor(map()) :: Phoenix.LiveView.Rendered.t()
  def recurrence_editor(assigns) do
    parsed = RRule.parse(assigns.recurrence_rule || "")

    assigns =
      assigns
      |> assign(:parsed, parsed)
      |> assign(:freq, parsed[:freq])
      |> assign(:interval, parsed[:interval] || 1)
      |> assign(:by_day, parsed[:by_day] || [])
      |> assign(:end_type, end_type(parsed))
      |> assign(:count, parsed[:count] || 10)
      |> assign(:until, until_value(parsed[:until]))
      |> assign(:weekdays, @weekdays)
      |> assign(:freq_options, @freq_options)
      |> assign(:summary, summary(parsed))

    ~H"""
    <div class="flex items-start gap-3">
      <.icon name="hero-arrow-path" class="w-4 h-4 text-tymeslot-400 mt-0.5 shrink-0" />
      <div class="flex-1">
        <p class="text-token-xs font-medium text-tymeslot-400 mb-1.5">Repeat</p>

        <form id={"recurrence-editor-form-#{@change_event}"} phx-change={@change_event} phx-target={@myself} class="space-y-2">
          <select
            name="freq"
            class="w-full rounded-md border-tymeslot-300 text-token-xs text-tymeslot-700 focus:border-turquoise-500 focus:ring-turquoise-500 py-1"
          >
            <option :for={{value, label} <- @freq_options} value={value} selected={to_string(@freq) == value}>
              {label}
            </option>
          </select>

          <div :if={@freq != nil} class="space-y-2 pl-0.5">
            <div class="flex items-center gap-2">
              <label class="text-token-xs text-tymeslot-600">Every</label>
              <input
                type="number"
                name="interval"
                min="1"
                max="999"
                value={@interval}
                class="w-16 rounded-md border-tymeslot-300 text-token-xs text-tymeslot-700 focus:border-turquoise-500 focus:ring-turquoise-500 py-1"
              />
              <span class="text-token-xs text-tymeslot-600">{interval_unit(@freq)}</span>
            </div>

            <div :if={@freq == :weekly} class="flex flex-wrap gap-1">
              <label
                :for={{day, label} <- @weekdays}
                class={[
                  "px-2 py-1 rounded-md border text-token-xs cursor-pointer transition-all select-none",
                  if(day in @by_day,
                    do: "border-turquoise-400 bg-turquoise-50 text-turquoise-800 font-semibold",
                    else: "border-tymeslot-200 text-tymeslot-600 hover:border-tymeslot-300 hover:bg-tymeslot-50"
                  )
                ]}
              >
                <input
                  type="checkbox"
                  name="by_day[]"
                  value={day}
                  checked={day in @by_day}
                  class="sr-only"
                />
                {label}
              </label>
            </div>

            <div class="flex flex-wrap items-center gap-2">
              <select
                name="end_type"
                class="rounded-md border-tymeslot-300 text-token-xs text-tymeslot-700 focus:border-turquoise-500 focus:ring-turquoise-500 py-1"
              >
                <option value="never" selected={@end_type == "never"}>Never ends</option>
                <option value="count" selected={@end_type == "count"}>After</option>
                <option value="until" selected={@end_type == "until"}>On date</option>
              </select>

              <div :if={@end_type == "count"} class="flex items-center gap-1.5">
                <input
                  type="number"
                  name="count"
                  min="1"
                  max="999"
                  value={@count}
                  class="w-16 rounded-md border-tymeslot-300 text-token-xs text-tymeslot-700 focus:border-turquoise-500 focus:ring-turquoise-500 py-1"
                />
                <span class="text-token-xs text-tymeslot-600">occurrences</span>
              </div>

              <input
                :if={@end_type == "until"}
                type="date"
                name="until"
                value={@until}
                class="rounded-md border-tymeslot-300 text-token-xs text-tymeslot-700 focus:border-turquoise-500 focus:ring-turquoise-500 py-1"
              />
            </div>
          </div>
        </form>

        <p :if={@summary != nil} class="text-token-xs text-tymeslot-400 mt-1.5">
          {@summary}
        </p>
      </div>
    </div>
    """
  end

  @doc """
  Returns a human-readable summary of an RRULE option map, e.g.
  "Repeats weekly on Mon, Wed". Returns `nil` for a non-recurring rule.
  """
  @spec summary(map()) :: String.t() | nil
  def summary(%{freq: freq} = parsed) do
    [base_phrase(freq, parsed), by_day_phrase(parsed), end_phrase(parsed)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  def summary(_parsed), do: nil

  defp base_phrase(freq, parsed) do
    interval = Map.get(parsed, :interval, 1)

    if interval > 1 do
      "Repeats every #{interval} #{plural_unit(freq, interval)}"
    else
      "Repeats #{freq_adverb(freq)}"
    end
  end

  defp freq_adverb(:daily), do: "daily"
  defp freq_adverb(:weekly), do: "weekly"
  defp freq_adverb(:monthly), do: "monthly"
  defp freq_adverb(:yearly), do: "yearly"

  defp plural_unit(:daily, _n), do: "days"
  defp plural_unit(:weekly, _n), do: "weeks"
  defp plural_unit(:monthly, _n), do: "months"
  defp plural_unit(:yearly, _n), do: "years"

  defp by_day_phrase(%{freq: :weekly, by_day: [_first | _rest] = days}) do
    "on " <> Enum.map_join(days, ", ", &weekday_label/1)
  end

  defp by_day_phrase(_parsed), do: nil

  defp end_phrase(%{count: count}) when is_integer(count), do: "for #{count} occurrences"

  defp end_phrase(%{until: %Date{} = until}), do: "until #{Date.to_iso8601(until)}"

  defp end_phrase(_parsed), do: nil

  defp weekday_label(day) do
    {_atom, label} = Enum.find(@weekdays, fn {atom, _label} -> atom == day end)
    label
  end

  defp end_type(%{count: count}) when is_integer(count), do: "count"
  defp end_type(%{until: %Date{}}), do: "until"
  defp end_type(_parsed), do: "never"

  defp until_value(%Date{} = date), do: Date.to_iso8601(date)
  defp until_value(_other), do: ""

  defp interval_unit(:daily), do: "day(s)"
  defp interval_unit(:weekly), do: "week(s)"
  defp interval_unit(:monthly), do: "month(s)"
  defp interval_unit(:yearly), do: "year(s)"
  defp interval_unit(_other), do: ""
end
