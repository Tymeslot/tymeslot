defmodule TymeslotWeb.Themes.Shared.Blocks.DayChips do
  @moduledoc """
  The next days the organiser has free, as a row of chips for the slot's
  date: "Today", "Tomorrow", then the weekday and the day of the month ("Thu
  9"). Built from the month's availability the flow already fetches
  (`month_availability_map`, ISO date => whether the day has a free time), so
  it costs no request of its own: the first `count` free days from today in
  the visitor's `user_timezone`.

  A chip is a button for the date fact (`data-fact="date"`, `data-value` the
  ISO date) sending `select_date`, with its full date as accessible name (a
  visually hidden full date beside the visible label, as `NextSlots` does,
  not an `aria-label`) and `aria-pressed` on the chosen day; the row is a
  group labelled "Select a Date". While the availability has not arrived it
  says it is loading, and when the fetch failed it says the calendar is
  slow; when no day of the loaded window is free it says so, and the theme
  offers its way on (a month calendar, the next month). Clicks go to
  `target`.

  Classes: `day-chips`, `__list`, `__chip` (`--selected`, `--today`),
  `__label`, `__loading`, `__error`, `__empty`. The shared structure is
  `scheduling/shared/blocks/day-chips.css`, on tokens only; `--day-chips-gap`
  changes the space between chips.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Live.Scheduling.CalendarHelpers
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  attr :availability, :any,
    required: true,
    doc: "the flow's `month_availability_map`; nil before a fetch, `:loading` during one"

  attr :availability_status, :atom,
    default: :not_loaded,
    doc: "the flow's `availability_status`: `:not_loaded`, `:loading`, `:loaded` or `:error`"

  attr :user_timezone, :string,
    required: true,
    doc: "the visitor's timezone; \"Today\" is the date it is now there"

  attr :selected_date, :string, default: nil
  attr :count, :integer, default: 7
  attr :target, :any, required: true

  @spec day_chips(map()) :: Phoenix.LiveView.Rendered.t()
  def day_chips(assigns) do
    today = CalendarHelpers.visitor_today(assigns.user_timezone)

    assigns =
      assign(assigns,
        today: today,
        days: free_days(assigns.availability, today, assigns.count)
      )

    ~H"""
    <div class="day-chips" data-testid="day-chips">
      <%= cond do %>
        <% @days != [] -> %>
          <div class="day-chips__list" role="group" aria-label={dgettext("booking", "Select a Date")}>
            <button
              :for={day <- @days}
              type="button"
              class={[
                "day-chips__chip",
                @selected_date == Date.to_iso8601(day) && "day-chips__chip--selected",
                day == @today && "day-chips__chip--today"
              ]}
              data-fact="date"
              data-value={Date.to_iso8601(day)}
              phx-click="select_date"
              phx-value-date={Date.to_iso8601(day)}
              phx-target={@target}
              aria-pressed={to_string(@selected_date == Date.to_iso8601(day))}
            >
              <span class="day-chips__label" aria-hidden="true">{day_label(day, @today)}</span>
              <span class="sr-only">{LocalizationHelpers.format_full_date_label(day)}</span>
            </button>
          </div>
        <% @availability_status == :error -> %>
          <p class="day-chips__error" role="status">
            {dgettext("booking", "Calendar is loading slowly")}
          </p>
        <% is_nil(@availability) or @availability == :loading or @availability_status == :loading -> %>
          <p class="day-chips__loading" role="status">
            {dgettext("booking", "Loading available times...")}
          </p>
        <% true -> %>
          <p class="day-chips__empty">{dgettext("booking", "No times available")}</p>
      <% end %>
    </div>
    """
  end

  @doc """
  How a visitor says `day` seen from `today`: "Today", "Tomorrow", else the
  short weekday and the day of the month ("Thu 9").
  """
  @spec day_label(Date.t(), Date.t()) :: String.t()
  def day_label(day, today) do
    case Date.diff(day, today) do
      0 ->
        dgettext("booking", "Today")

      1 ->
        dgettext("booking", "Tomorrow")

      _later ->
        dgettext("booking", "%{weekday} %{day}", weekday: weekday_short(day), day: day.day)
    end
  end

  # Monday-first headings line up with `Date.day_of_week/1`, Monday 1 to
  # Sunday 7.
  defp weekday_short(day),
    do: Enum.at(LocalizationHelpers.weekday_headings(:monday), Date.day_of_week(day) - 1)

  defp free_days(availability, today, count) when is_map(availability) do
    availability
    |> Enum.filter(fn {_iso, free} -> free == true end)
    |> Enum.flat_map(fn {iso, _free} ->
      case Date.from_iso8601(iso) do
        {:ok, day} -> [day]
        {:error, _reason} -> []
      end
    end)
    |> Enum.reject(&(Date.compare(&1, today) == :lt))
    |> Enum.sort(Date)
    |> Enum.take(count)
  end

  defp free_days(_availability, _today, _count), do: []
end
