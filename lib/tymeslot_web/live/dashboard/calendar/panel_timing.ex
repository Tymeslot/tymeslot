defmodule TymeslotWeb.Dashboard.Calendar.PanelTiming do
  @moduledoc """
  The side panel's All day, Starts and Ends fields: what they show for an
  event, and the change an edit of one of them makes.

  Times are walls on the organiser's clock (`"YYYY-MM-DDTHH:MM"`), resolved
  to instants by the domain's timing rules (`Changes.resolve_timing/4`):
  a changed start draws the end at the event's current wall length after
  it, which those rules keep as the event's real length; a changed end is
  taken as drawn, and must come after the start.

  All-day dates are shown inclusive and stored exclusive (see
  `Tymeslot.CalendarGrid.AllDay`): a changed first day keeps the number of
  days, a changed last day is stored as the day after it. Toggling all day
  goes through `EventEdit.toggle_all_day/2` in the zone
  `RepeatForm.all_day_timezone/2` gives.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CalendarGrid.AllDay
  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.CalendarGrid.EventEdit
  alias Tymeslot.CalendarGrid.EventPayload
  alias Tymeslot.CalendarGrid.Moves
  alias TymeslotWeb.Components.Calendar.RepeatForm
  alias TymeslotWeb.Components.UI.StatusSwitch

  @timed_fields ~w(start_date start_time end_date end_time)
  @day_fields ~w(start_date end_date)

  @doc "The fields' values for `event`, on the organiser's clock in `timezone`."
  @spec fields(map(), String.t()) :: map()
  def fields(%{all_day: true, start_date: %Date{} = first} = event, _timezone) do
    %{
      all_day: true,
      start_date: Date.to_iso8601(first),
      start_time: nil,
      end_date: first |> AllDay.last_day(EventPayload.exclusive_end(event)) |> Date.to_iso8601(),
      end_time: nil
    }
  end

  def fields(%{start_at: %DateTime{} = start_at, end_at: %DateTime{} = end_at}, timezone) do
    starts = DateTime.shift_zone!(start_at, timezone)
    ends = DateTime.shift_zone!(end_at, timezone)

    %{
      all_day: false,
      start_date: starts |> DateTime.to_date() |> Date.to_iso8601(),
      start_time: hour_minute(starts),
      end_date: ends |> DateTime.to_date() |> Date.to_iso8601(),
      end_time: hour_minute(ends)
    }
  end

  @doc """
  The change editing the field `params["_target"]` names makes to `event`,
  with the write's options; `:unchanged` for no change or a field still
  empty; or why it cannot be written.
  """
  @spec change(map(), map(), String.t()) ::
          {:ok, map(), keyword()} | :unchanged | {:error, String.t()}
  def change(%{all_day: true} = event, %{"_target" => [target | _rest]} = params, timezone)
      when target in @day_fields,
      do: change_days(event, target, params, timezone)

  def change(
        %{start_at: %DateTime{}} = event,
        %{"_target" => [target | _rest]} = params,
        timezone
      )
      when target in @timed_fields,
      do: change_times(event, target, params, timezone)

  def change(_event, _params, _timezone), do: :unchanged

  @doc """
  The change toggling all day makes to `event`, and the write's options; an
  all-day event longer than a timed one may be cannot become timed.
  """
  @spec toggle_all_day(map(), String.t()) :: {:ok, map(), keyword()} | {:error, String.t()}
  def toggle_all_day(event, timezone) do
    zone = RepeatForm.all_day_timezone(event, timezone)
    toggled = EventEdit.toggle_all_day(event, zone)

    case toggled do
      %{start_at: %DateTime{} = start_at, end_at: %DateTime{} = end_at} ->
        if Moves.sensible?(start_at, end_at),
          do: {:ok, EventEdit.timing_changes(toggled), timezone: zone},
          else: {:error, too_long()}

      _all_day ->
        {:ok, EventEdit.timing_changes(toggled), timezone: zone}
    end
  end

  defp change_times(event, target, params, timezone) do
    current = fields(event, timezone)

    with {:ok, start_wall} <- wall(params, "start", current),
         {:ok, end_wall} <- end_wall(target, params, current, start_wall),
         :ok <- after_start(start_wall, end_wall),
         {:ok, %{start_at: start_at, end_at: end_at}} <-
           Changes.resolve_timing(event, start_wall, end_wall, timezone) do
      if same?(start_at, event.start_at) and same?(end_at, event.end_at),
        do: :unchanged,
        else: {:ok, %{start_at: start_at, end_at: end_at}, []}
    else
      :incomplete -> :unchanged
      {:error, :end_before_start} -> {:error, end_before_start(:time)}
      {:error, :out_of_range} -> {:error, out_of_range()}
      {:error, _invalid_time} -> {:error, too_long()}
    end
  end

  # A changed start draws the end at the event's wall length after it.
  defp end_wall(target, _params, current, start_wall) when target in ~w(start_date start_time) do
    {:ok, start} = NaiveDateTime.from_iso8601(wall_text(current.start_date, current.start_time))
    {:ok, finish} = NaiveDateTime.from_iso8601(wall_text(current.end_date, current.end_time))
    {:ok, new_start} = NaiveDateTime.from_iso8601(start_wall <> ":00")

    {:ok, new_start |> NaiveDateTime.add(NaiveDateTime.diff(finish, start)) |> to_wall()}
  end

  defp end_wall(_end_target, params, current, _start_wall), do: wall(params, "end", current)

  defp wall(params, side, current) do
    date =
      present(params["#{side}_date"]) ||
        Map.fetch!(current, String.to_existing_atom("#{side}_date"))

    time =
      present(params["#{side}_time"]) ||
        Map.fetch!(current, String.to_existing_atom("#{side}_time"))

    with true <- is_binary(date) and is_binary(time),
         text = wall_text(date, String.slice(time, 0, 5)),
         {:ok, naive} <- NaiveDateTime.from_iso8601(text) do
      {:ok, to_wall(naive)}
    else
      _incomplete -> :incomplete
    end
  end

  defp after_start(start_wall, end_wall) do
    if NaiveDateTime.compare(naive(end_wall), naive(start_wall)) == :gt,
      do: :ok,
      else: {:error, :end_before_start}
  end

  defp change_days(event, target, params, timezone) do
    with {:ok, first} <- Date.from_iso8601(params["start_date"] || ""),
         {:ok, last} <- Date.from_iso8601(params["end_date"] || ""),
         {:ok, first, exclusive_end} <- days(target, first, last, event),
         :ok <- day_span(first, exclusive_end) do
      if first == event.start_date and exclusive_end == EventPayload.exclusive_end(event),
        do: :unchanged,
        else:
          {:ok, %{start_date: first, end_date: exclusive_end},
           [timezone: RepeatForm.all_day_timezone(event, timezone)]}
    else
      {:error, :end_before_start} -> {:error, end_before_start(:date)}
      {:error, :out_of_range} -> {:error, out_of_range()}
      {:error, :too_long} -> {:error, too_long_all_day()}
      {:error, _incomplete} -> :unchanged
    end
  end

  defp day_span(first, exclusive_end) do
    cond do
      first.year not in Moves.years() or exclusive_end.year not in Moves.years() ->
        {:error, :out_of_range}

      Moves.sensible_days?(first, exclusive_end) ->
        :ok

      true ->
        {:error, :too_long}
    end
  end

  # A new first day keeps the number of days; a new last day is stored as
  # the day after it.
  defp days("start_date", first, _last, event) do
    span = Date.diff(EventPayload.exclusive_end(event), event.start_date)
    {:ok, first, Date.add(first, span)}
  end

  defp days("end_date", first, last, _event) do
    if Date.compare(last, first) == :lt,
      do: {:error, :end_before_start},
      else: {:ok, first, Date.add(last, 1)}
  end

  defp end_before_start(:time),
    do:
      dgettext(
        "dashboard_calendar_editing",
        "The end is before the start. Pick a later end time."
      )

  defp end_before_start(:date),
    do:
      dgettext(
        "dashboard_calendar_editing",
        "The end is before the start. Pick a later end date."
      )

  defp out_of_range,
    do: dgettext("dashboard_calendar_editing", "Pick a date between 1900 and 2200.")

  defp too_long_all_day,
    do:
      dgettext("dashboard_calendar_editing", "An all-day event can last up to %{count} days.",
        count: Moves.max_all_day_days()
      )

  defp too_long, do: dgettext("dashboard_calendar_editing", "An event can last up to 7 days.")

  defp hour_minute(at), do: at |> DateTime.to_time() |> Calendar.strftime("%H:%M")

  defp wall_text(date, time), do: "#{date}T#{time}:00"

  defp to_wall(naive), do: Calendar.strftime(naive, "%Y-%m-%dT%H:%M")

  defp naive(wall), do: NaiveDateTime.from_iso8601!(wall <> ":00")

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  defp same?(a, b), do: DateTime.compare(a, b) == :eq

  attr :timing, :map, required: true
  attr :disabled, :boolean, default: false

  attr :reason, :string,
    default: nil,
    doc: "why the timing cannot be changed, shown under it when `disabled`"

  attr :error, :string, default: nil
  attr :target, :any, required: true

  @doc "All day, Starts and Ends; with a `reason`, why they cannot be changed."
  @spec timing_fields(map()) :: Phoenix.LiveView.Rendered.t()
  def timing_fields(assigns) do
    ~H"""
    <div class="space-y-3">
      <div class="flex items-center justify-between gap-3">
        <span class="text-token-sm font-medium text-tymeslot-700" aria-hidden="true">
          {dgettext("dashboard_calendar_editing", "All day")}
        </span>
        <StatusSwitch.status_switch
          id="calendar-panel-all-day"
          checked={@timing.all_day}
          on_change="panel:all_day"
          target={@target}
          size={:small}
          disabled={@disabled}
          aria_label={dgettext("dashboard_calendar_editing", "All day")}
        />
      </div>
      <form id="calendar-panel-timing" phx-change="panel:timing" phx-target={@target} novalidate>
        <fieldset
          disabled={@disabled}
          aria-describedby={@disabled && @reason && "calendar-panel-timing-locked"}
          class="space-y-2"
        >
          <div class="grid grid-cols-2 gap-2">
            <.date_picker
              id="calendar-panel-start-date"
              name="start_date"
              label={dgettext("dashboard_calendar_editing", "Starts")}
              value={@timing.start_date}
              disabled={@disabled}
            />
            <.time_picker
              :if={!@timing.all_day}
              id="calendar-panel-start-time"
              name="start_time"
              label={dgettext("dashboard_calendar_editing", "Start time")}
              value={@timing.start_time}
              disabled={@disabled}
            />
          </div>
          <div class="grid grid-cols-2 gap-2">
            <.date_picker
              id="calendar-panel-end-date"
              name="end_date"
              label={dgettext("dashboard_calendar_editing", "Ends")}
              value={@timing.end_date}
              errors={List.wrap(@error)}
              disabled={@disabled}
            />
            <.time_picker
              :if={!@timing.all_day}
              id="calendar-panel-end-time"
              name="end_time"
              label={dgettext("dashboard_calendar_editing", "End time")}
              value={@timing.end_time}
              disabled={@disabled}
            />
          </div>
        </fieldset>
      </form>
      <p
        :if={@disabled && @reason}
        id="calendar-panel-timing-locked"
        class="flex items-start gap-1.5 text-token-sm text-tymeslot-500"
      >
        <.icon name="hero-lock-closed-micro" class="mt-0.5 h-3.5 w-3.5 shrink-0" />
        <span>{@reason}</span>
      </p>
    </div>
    """
  end
end
