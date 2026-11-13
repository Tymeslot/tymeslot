defmodule TymeslotWeb.Dashboard.Polls.AvailabilityWeek do
  @moduledoc """
  The week grid on the poll create form (`PollForm`): seven days in
  half-hour steps, in the poll's timezone, showing where the host is busy
  and where their working hours end, so they can pick candidate times in
  one pass. Clicking a time adds it as a candidate; clicking a candidate's
  start removes it.

  Each step is judged for a meeting the poll's length starting there
  (`Tymeslot.Polls.HostAvailability.status/3`), so the busy stretch grows
  with the duration. The voting deadline is drawn as a line where it falls.
  Busy and outside-hours times stay clickable: like the warnings under the
  rows, this is a hint, and confirmation is the binding check.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Clock
  alias Tymeslot.Polls.HostAvailability
  alias Tymeslot.Utils.DateTimeUtils.TimeFormat
  alias TymeslotWeb.Components.CoreComponents.{Buttons, Icons}
  alias TymeslotWeb.Dashboard.DashboardFormat
  alias TymeslotWeb.Dashboard.Polls.LocalTime

  @step_minutes 30
  @days 7
  # The hours shown when nothing in the week reaches further.
  @default_hours {8, 20}

  @doc "The day a fresh form's grid opens on: today, in `timezone`."
  @spec today(String.t(), DateTime.t()) :: Date.t()
  def today(timezone, now \\ Clock.utc_now()) do
    case DateTime.shift_zone(now, timezone) do
      {:ok, local} -> DateTime.to_date(local)
      {:error, _reason} -> DateTime.to_date(now)
    end
  end

  @doc """
  The week shown `offset` weeks on from today in `timezone`: its first day,
  and the UTC stretch to read the host's availability for, a day past the
  last one shown so a meeting starting late on it is judged whole. The form
  keeps the offset rather than the day, so the grid follows the poll's
  timezone when it changes.
  """
  @spec week(String.t(), non_neg_integer(), DateTime.t()) ::
          {Date.t(), {DateTime.t(), DateTime.t()}}
  def week(timezone, offset, now \\ Clock.utc_now()) do
    first_day = timezone |> today(now) |> Date.add(offset * @days)

    {first_day,
     {midnight(first_day, timezone), midnight(Date.add(first_day, @days + 1), timezone)}}
  end

  @doc """
  The week offset after a step `direction` ("prev" or "next") from `offset`,
  never before this week.
  """
  @spec shift(non_neg_integer(), String.t()) :: non_neg_integer()
  def shift(offset, "next"), do: offset + 1
  def shift(offset, "prev"), do: max(offset - 1, 0)
  def shift(offset, _direction), do: offset

  @doc """
  What clicking the step `value` does to `rows`: `{:remove, key}` when a
  candidate starts within that step (the step the grid draws it on, so a
  time typed off the half hour is removed from where it shows), `:add`
  otherwise.
  """
  @spec toggle([%{key: integer(), value: String.t()}], String.t()) ::
          {:remove, String.t()} | :add
  def toggle(rows, value) do
    with %NaiveDateTime{} = step <- naive(value),
         step_end = NaiveDateTime.add(step, @step_minutes, :minute),
         %{key: key} <- Enum.find(rows, &starts_within?(naive(&1.value), step, step_end)) do
      {:remove, to_string(key)}
    else
      _no_candidate -> :add
    end
  end

  defp starts_within?(nil, _from, _to), do: false
  defp starts_within?(moment, from, to), do: within?(moment, from, to)

  attr :id, :string, required: true
  attr :first_day, Date, required: true
  attr :timezone, :string, required: true
  attr :minutes, :integer, default: nil, doc: "the poll's length, nil while unreadable"

  attr :availability, :any,
    default: nil,
    doc: "`HostAvailability.t()`, `:loading`, or nil when it could not be read"

  attr :slots, :list, required: true
  attr :deadline, :string, default: ""
  attr :time_format, :string, default: nil

  attr :now, DateTime,
    default: nil,
    doc: "the moment before which steps are past; now unless given"

  attr :myself, :any, required: true

  @doc "The grid."
  @spec grid(map()) :: Phoenix.LiveView.Rendered.t()
  def grid(assigns) do
    assigns = assign(assigns, :now, assigns.now || Clock.utc_now())
    assigns = assign(assigns, today: today(assigns.timezone, assigns.now), grid: build(assigns))

    ~H"""
    <div id={@id} class="space-y-2" data-testid="poll-availability-week">
      <div class="flex items-center justify-between gap-2">
        <p class="text-token-xs text-tymeslot-600">
          {dgettext(
            "dashboard_polls",
            "Click a time to add it as a candidate, or click a candidate to remove it."
          )}
        </p>
        <div class="flex items-center gap-1 shrink-0">
          <Buttons.icon_button
            icon="hero-chevron-left"
            label={dgettext("dashboard_polls", "Previous week")}
            size={:sm}
            disabled={Date.compare(@first_day, @today) != :gt}
            phx-click="availability_week"
            phx-value-to="prev"
            phx-target={@myself}
          />
          <Buttons.icon_button
            icon="hero-chevron-right"
            label={dgettext("dashboard_polls", "Next week")}
            size={:sm}
            phx-click="availability_week"
            phx-value-to="next"
            phx-target={@myself}
          />
        </div>
      </div>

      <div class="overflow-x-auto rounded-token-lg border border-tymeslot-200">
        <div
          class="grid min-w-[36rem] grid-cols-[3.5rem_repeat(7,minmax(0,1fr))] bg-tymeslot-200 gap-px"
          role="group"
          aria-label={dgettext("dashboard_polls", "Your week")}
        >
          <div class="bg-white"></div>
          <div
            :for={day <- @grid.days}
            class="bg-white px-1 py-2 text-center text-token-xs font-medium text-tymeslot-700"
          >
            {day.label}
          </div>
          <%!-- `contents` keeps each row's cells on the grid; the keys let
                LiveView send only the rows and cells that changed. --%>
          <div :for={time <- @grid.times} :key={time.time} class="contents">
            <div class="bg-white pr-2 text-right text-token-xs leading-none text-tymeslot-500">
              {if time.label, do: time.label}
            </div>
            <%!-- native-title: repeats the cell's aria-label; the row and column
                 headings and the legend carry the same, and a 20px cell has no
                 room for a bubble. --%>
            <button
              :for={cell <- Enum.map(@grid.days, &Map.fetch!(&1.cells, time.time))}
              :key={cell.value}
              type="button"
              class={["relative h-5", cell_class(cell)]}
              disabled={cell.past?}
              aria-pressed={to_string(cell.candidate == :start)}
              aria-label={cell.label}
              title={cell.label}
              data-at={cell.value}
              data-status={cell.status}
              phx-click="pick_time"
              phx-value-at={cell.value}
              phx-target={@myself}
            >
              <span
                :if={cell.deadline_at}
                class="pointer-events-none absolute inset-x-0 border-t-2 border-amber-500"
                style={"top: #{cell.deadline_at}%"}
                data-testid="poll-deadline-marker"
              ></span>
            </button>
          </div>
        </div>
      </div>

      <div class="flex flex-wrap items-center gap-x-4 gap-y-1 text-token-xs text-tymeslot-600">
        <.swatch class="bg-white border border-tymeslot-200" label={status_label(:free)} />
        <.swatch class="poll-availability-busy" label={status_label(:busy)} />
        <.swatch class="bg-tymeslot-100" label={status_label(:outside_hours)} />
        <.swatch class="bg-turquoise-500" label={dgettext("dashboard_polls", "Candidate time")} />
        <span :if={@grid.deadline_label} class="flex items-center gap-1">
          <span class="inline-block w-4 border-t-2 border-amber-500"></span>
          {dgettext("dashboard_polls", "Voting closes %{when}", when: @grid.deadline_label)}
        </span>
        <span :if={@availability == :loading} class="flex items-center gap-1">
          <Icons.icon name="hero-arrow-path-mini" class="w-4 h-4 animate-spin" />
          {dgettext("dashboard_polls", "Checking your calendar…")}
        </span>
      </div>
    </div>
    """
  end

  attr :class, :string, required: true
  attr :label, :string, required: true

  defp swatch(assigns) do
    ~H"""
    <span class="flex items-center gap-1">
      <span class={["inline-block w-3 h-3 rounded-token-sm", @class]}></span>
      {@label}
    </span>
    """
  end

  defp cell_class(%{past?: true}), do: "bg-tymeslot-100 cursor-not-allowed opacity-60"
  defp cell_class(%{candidate: :start}), do: "bg-turquoise-500 hover:bg-turquoise-600"
  defp cell_class(%{candidate: :covered}), do: "bg-turquoise-200 hover:bg-turquoise-300"
  defp cell_class(%{status: :busy}), do: "poll-availability-busy hover:bg-turquoise-50"
  defp cell_class(%{status: :outside_hours}), do: "bg-tymeslot-100 hover:bg-turquoise-50"
  defp cell_class(_free_or_unknown), do: "bg-white hover:bg-turquoise-50"

  defp status_label(:free), do: dgettext("dashboard_polls", "Free")
  defp status_label(:busy), do: dgettext("dashboard_polls", "Busy")
  defp status_label(:outside_hours), do: dgettext("dashboard_polls", "Outside working hours")

  # --- Building the grid ---

  defp build(assigns) do
    %{first_day: first_day, timezone: timezone, slots: slots} = assigns
    dates = Enum.map(0..(@days - 1), &Date.add(first_day, &1))
    minutes = meeting_minutes(assigns.minutes)
    candidates = slots |> Enum.map(&naive(&1.value)) |> Enum.reject(&is_nil/1)
    deadline = naive(assigns.deadline)
    times = times(dates, assigns.availability, candidates, deadline, timezone)

    context = %{
      assigns: assigns,
      minutes: minutes,
      candidates: candidates,
      deadline: deadline
    }

    %{
      times: Enum.map(times, &time_row(&1, assigns.time_format)),
      days:
        Enum.map(dates, fn date ->
          %{
            label: DashboardFormat.short_date(date),
            cells: Map.new(times, &{&1, cell(date, &1, context)})
          }
        end),
      deadline_label: deadline && deadline_label(deadline, assigns.time_format)
    }
  end

  # A length still being typed (blank, 0, negative) is judged as one step,
  # as `HostAvailability.status/3` measures only a real meeting.
  defp meeting_minutes(minutes) when is_integer(minutes) and minutes > 0, do: minutes
  defp meeting_minutes(_unreadable), do: @step_minutes

  defp time_row(time, time_format),
    do: %{time: time, label: if(time.minute == 0, do: TimeFormat.format(time, time_format))}

  defp cell(date, time, %{assigns: assigns} = context) do
    local = NaiveDateTime.new!(date, time)
    value = local |> NaiveDateTime.to_iso8601() |> String.slice(0, 16)
    start_time = LocalTime.to_utc(value, assigns.timezone)
    past? = start_time == nil or DateTime.compare(start_time, assigns.now) != :gt

    status =
      if is_map(assigns.availability) and start_time != nil,
        do: HostAvailability.status(assigns.availability, start_time, context.minutes)

    candidate = candidate(local, context)

    %{
      value: value,
      past?: past?,
      status: status,
      candidate: candidate,
      deadline_at: deadline_offset(local, context.deadline),
      label: cell_label(date, time, status, candidate, assigns.time_format)
    }
  end

  defp candidate(local, %{candidates: candidates, minutes: minutes}) do
    step_end = NaiveDateTime.add(local, @step_minutes, :minute)

    cond do
      Enum.any?(candidates, &within?(&1, local, step_end)) ->
        :start

      Enum.any?(
        candidates,
        &(before?(&1, step_end) and
              before?(local, NaiveDateTime.add(&1, minutes, :minute)))
      ) ->
        :covered

      true ->
        nil
    end
  end

  # The percentage down the step at which the deadline falls, when it does.
  defp deadline_offset(_local, nil), do: nil

  defp deadline_offset(local, deadline) do
    if within?(deadline, local, NaiveDateTime.add(local, @step_minutes, :minute)),
      do: round(NaiveDateTime.diff(deadline, local, :minute) / @step_minutes * 100)
  end

  defp within?(moment, from, to), do: not before?(moment, from) and before?(moment, to)
  defp before?(a, b), do: NaiveDateTime.compare(a, b) == :lt

  defp cell_label(date, time, status, candidate, time_format) do
    when_text =
      dgettext("dashboard_polls", "%{day} at %{time}",
        day: DashboardFormat.short_date(date),
        time: TimeFormat.format(time, time_format)
      )

    detail =
      cond do
        candidate == :start -> dgettext("dashboard_polls", "Candidate time")
        status -> status_label(status)
        true -> nil
      end

    if detail, do: "#{when_text}: #{detail}", else: when_text
  end

  defp deadline_label(deadline, time_format) do
    dgettext("dashboard_polls", "%{day} at %{time}",
      day: DashboardFormat.short_date(NaiveDateTime.to_date(deadline)),
      time: TimeFormat.format(deadline, time_format)
    )
  end

  # The half-hour steps shown: the default hours, widened to take in the
  # working hours, the candidates and the deadline that fall in the week.
  defp times(dates, availability, candidates, deadline, timezone) do
    week = {List.first(dates), Date.add(List.last(dates), 1)}

    open =
      availability
      |> open_hours(timezone)
      |> Enum.filter(fn {from, _to} -> in_week?(from, week) end)

    marks = Enum.filter(candidates ++ List.wrap(deadline), &in_week?(&1, week))
    {from, to} = hour_bounds(open ++ Enum.map(marks, &{&1, NaiveDateTime.add(&1, 1, :second)}))

    for hour <- from..(to - 1)//1, minute <- [0, @step_minutes], do: Time.new!(hour, minute, 0)
  end

  # The first hour and the hour after the last that `stretches` need shown.
  defp hour_bounds(stretches) do
    {default_from, default_to} = @default_hours

    {
      Enum.min([default_from | Enum.map(stretches, &elem(&1, 0).hour)]),
      Enum.max([default_to | Enum.map(stretches, fn {from, to} -> end_hour(from, to) end)])
    }
  end

  defp in_week?(moment, {first, last}) do
    date = NaiveDateTime.to_date(moment)
    Date.compare(date, first) != :lt and Date.compare(date, last) == :lt
  end

  # The hour a stretch ends in, on the day it opens: 24 past midnight.
  defp end_hour(from, to) do
    if NaiveDateTime.to_date(to) != NaiveDateTime.to_date(from),
      do: 24,
      else: if({to.minute, to.second} == {0, 0}, do: to.hour, else: to.hour + 1)
  end

  defp open_hours(%{hours: hours}, timezone) when is_list(hours),
    do: Enum.map(hours, fn {from, to} -> {local(from, timezone), local(to, timezone)} end)

  defp open_hours(_availability, _timezone), do: []

  defp local(datetime, timezone) do
    case DateTime.shift_zone(datetime, timezone) do
      {:ok, shifted} -> DateTime.to_naive(shifted)
      {:error, _reason} -> DateTime.to_naive(datetime)
    end
  end

  defp midnight(date, timezone) do
    date
    |> NaiveDateTime.new!(~T[00:00:00])
    |> NaiveDateTime.to_iso8601()
    |> LocalTime.to_utc(timezone) ||
      DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
  end

  defp naive(value) when is_binary(value) and value != "" do
    case NaiveDateTime.from_iso8601(normalise(value)) do
      {:ok, naive} -> NaiveDateTime.truncate(naive, :second)
      {:error, _reason} -> nil
    end
  end

  defp naive(_blank), do: nil

  defp normalise(value), do: if(String.length(value) == 16, do: value <> ":00", else: value)
end
