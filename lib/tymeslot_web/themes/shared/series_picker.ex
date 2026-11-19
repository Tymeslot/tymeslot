defmodule TymeslotWeb.Themes.Shared.SeriesPicker do
  @moduledoc """
  A flexible series' picker of further sessions (`Journey.Facts.Series`):
  one week of the meeting type's offered times at a time, fetched with
  `Tymeslot.Availability.Offer.slots_for_range/4` in a `start_async/3` task
  under `{:series_week, week_start}`, and offered after the first session
  and within a year of it, less the sessions already chosen. The host's
  booking window binds the first session only, so the fetch reaches the
  year past it (`Offer`'s `window_until:`).

  The host's calendar is read six weeks at a time, the six weeks holding
  the week asked for, counted from the first session's week, and each
  read is kept (`:series_weeks`) for the same first session, length and
  timezone, for five minutes: paging back over a week
  already shown, and reopening the picker after adding a session, read
  nothing, so a year of the picker costs nine reads. Each read is charged
  to the visitor (`Series.charge_read/1`). The picker opens on the week of
  the last session chosen. A time it offers from a kept read is checked
  afresh, with the whole series, once added.

  `:series_picker` is nil while the picker is closed, else `%{week_start,
  days, loading?, error, day}`: the week shown, its slots by ISO date (nil
  while loading), whether it is loading, why it could not be fetched, and
  the day whose times are on show. The `Series` fact routes the picker's
  events here and adds a session only when `offered/2` finds it.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [cancel_async: 2, start_async: 3]

  alias Phoenix.LiveView.Socket
  alias Tymeslot.Availability.Offer
  alias Tymeslot.BookingSeries.Check
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.Utils.DateTimeUtils
  alias TymeslotWeb.Live.Scheduling.AvailabilityHelpers
  alias TymeslotWeb.Live.Scheduling.WeekSlots
  alias TymeslotWeb.Themes.Shared.Journey.Facts.Series

  require Logger

  # How long a read of six weeks is kept, and how many days one read covers
  # (`Offer.slots_for_range/4` takes at most 42).
  @weeks_ttl_ms 5 * 60_000
  @block_days 42

  @doc """
  The flexible picker's offered sessions on the week it shows, by day, as
  `%{iso, date, times: [%{label, start}]}`: the type's free times after the
  first session and within a year of it, less the sessions already chosen.
  Empty while the picker is closed or its week is loading.
  """
  @spec days(map()) :: [%{iso: String.t(), date: Date.t(), times: [map()]}]
  def days(
        %{series_picker: %{days: %{} = days}, series_choice: %{starts: [first | _rest]} = choice} =
          assigns
      ) do
    last = DateTime.add(first, Check.span_days(), :day)
    tz = timezone(assigns)

    days
    |> WeekSlots.free_days(Date.add(DateTime.to_date(first), -1))
    |> Enum.map(fn %{iso: iso, date: date, slots: labels} ->
      times =
        for label <- labels,
            start = slot_start(date, label, tz),
            start != nil,
            DateTime.after?(start, first),
            not DateTime.after?(start, last),
            not Enum.any?(choice.starts, &(DateTime.compare(&1, start) == :eq)),
            do: %{label: label, start: start}

      %{iso: iso, date: date, times: times}
    end)
    |> Enum.reject(&(&1.times == []))
  end

  def days(_assigns), do: []

  @doc "Whether the picker may move a week earlier: not before the first session's week."
  @spec earlier?(map()) :: boolean()
  def earlier?(%{series_picker: %{week_start: week}} = assigns) do
    case Series.first_start(assigns) do
      nil -> false
      first -> Date.compare(week, first_week(assigns, first)) == :gt
    end
  end

  def earlier?(_assigns), do: false

  @doc "Whether the picker may move a week later: not past a year after the first session."
  @spec later?(map()) :: boolean()
  def later?(%{series_picker: %{week_start: week}} = assigns) do
    case Series.first_start(assigns) do
      nil ->
        false

      first ->
        Date.compare(Date.add(week, 7), Date.add(DateTime.to_date(first), Check.span_days())) !=
          :gt
    end
  end

  def later?(_assigns), do: false

  @doc "The offered session starting at `start`, or nil: what a booker may add."
  @spec offered(map(), DateTime.t()) :: %{label: String.t(), start: DateTime.t()} | nil
  def offered(assigns, start) do
    assigns
    |> days()
    |> Enum.flat_map(& &1.times)
    |> Enum.find(&(DateTime.compare(&1.start, start) == :eq))
  end

  @doc """
  The picker's six weeks, a `start_async/3` result, kept for the week it
  was read for; one for a week left behind is dropped.
  """
  @spec handle_async({:series_week, Date.t()}, term(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_async({:series_week, week}, result, socket) do
    case socket.assigns[:series_picker] do
      %{week_start: ^week, loading?: true} = picker ->
        {:noreply, socket |> keep_block(week, result) |> show_result(picker, result)}

      _other_week ->
        {:noreply, socket}
    end
  end

  @doc "Opens the picker on the week of the last session chosen."
  @spec open(Socket.t()) :: Socket.t()
  def open(%{assigns: %{series_choice: %{mode: :flexible, starts: starts}}} = socket) do
    case Series.first_start(socket.assigns) do
      nil -> socket
      _first -> fetch_week(socket, week_of(socket.assigns, List.last(starts)))
    end
  end

  def open(socket), do: socket

  @doc "Closes the picker, dropping a week still loading."
  @spec close(Socket.t()) :: Socket.t()
  def close(%{assigns: %{series_picker: %{week_start: week}}} = socket) do
    socket
    |> cancel_async({:series_week, week})
    |> assign(:series_picker, nil)
    |> assign(:series_refocus, true)
  end

  def close(socket), do: socket

  @doc ~S|Moves the picker a week, "prev" or "next", within the series' span.|
  @spec move(Socket.t(), term()) :: Socket.t()
  def move(%{assigns: %{series_picker: %{week_start: week}}} = socket, dir) do
    cond do
      dir == "next" and later?(socket.assigns) ->
        socket |> cancel_async({:series_week, week}) |> fetch_week(Date.add(week, 7))

      dir == "prev" and earlier?(socket.assigns) ->
        socket |> cancel_async({:series_week, week}) |> fetch_week(Date.add(week, -7))

      true ->
        socket
    end
  end

  def move(socket, _dir), do: socket

  @doc "Fetches the week on show again, after it could not be fetched."
  @spec retry(Socket.t()) :: Socket.t()
  def retry(%{assigns: %{series_picker: %{week_start: week, loading?: false}}} = socket),
    do: fetch_week(socket, week)

  def retry(socket), do: socket

  @doc "Shows the times of the day `iso`, when the picker offers it."
  @spec pick_day(Socket.t(), term()) :: Socket.t()
  def pick_day(%{assigns: %{series_picker: %{} = picker}} = socket, iso)
      when is_binary(iso) do
    if Enum.any?(days(socket.assigns), &(&1.iso == iso)),
      do: assign(socket, :series_picker, %{picker | day: iso}),
      else: socket
  end

  def pick_day(socket, _iso), do: socket

  # A week inside a kept read is shown from it. Otherwise its six weeks are
  # read, charged to the visitor (`Series.charge_read/1`); past the limit
  # nothing is read and the picker says so, with a retry.
  defp fetch_week(socket, week_start) do
    case kept_week(socket, week_start) do
      %{} = days ->
        assign(socket, :series_picker, picker(week_start, days, false, nil))

      nil ->
        case Series.charge_read(socket) do
          :ok ->
            start_block(socket, week_start)

          {:error, :rate_limited} ->
            assign(socket, :series_picker, picker(week_start, %{}, false, :rate_limited))
        end
    end
  end

  defp picker(week_start, days, loading?, error),
    do: %{week_start: week_start, days: days, loading?: loading?, error: error, day: nil}

  # The request and the duration are built before the task, so it captures
  # plain values and never the socket. The booking window binds the first
  # session only: the weeks may reach a year past it (`window_until:`).
  defp start_block(socket, week_start) do
    request =
      socket
      |> AvailabilityHelpers.request()
      |> Map.put(:window_until, window_until(socket.assigns))

    duration = AvailabilityHelpers.duration_minutes(socket)
    block = block_start(socket.assigns, week_start)
    block_end = Date.add(block, @block_days - 1)

    socket
    |> assign(:series_picker, picker(week_start, nil, true, nil))
    |> start_async(
      {:series_week, week_start},
      Tasks.with_context(fn -> Offer.slots_for_range(request, block, block_end, duration) end)
    )
  end

  defp show_result(socket, picker, {:ok, {:ok, days}}),
    do:
      assign(socket, :series_picker, %{
        picker
        | days: week_days(days, picker.week_start),
          loading?: false
      })

  defp show_result(socket, picker, {:ok, {:error, reason}}),
    do: assign(socket, :series_picker, week_failed(picker, reason))

  defp show_result(socket, picker, {:exit, reason}),
    do: assign(socket, :series_picker, week_failed(picker, reason))

  defp week_failed(picker, reason) do
    Logger.warning("Series picker week fetch failed", reason: LogFormat.reason(reason))
    %{picker | days: %{}, loading?: false, error: :availability_unverifiable}
  end

  # Kept reads

  # The reads kept answer one first session, length and timezone; another
  # of any of them starts afresh.
  defp weeks_key(socket) do
    assigns = socket.assigns

    {Series.first_start(assigns), Map.get(assigns[:meeting_type] || %{}, :id),
     AvailabilityHelpers.duration_minutes(socket), timezone(assigns)}
  end

  defp kept_week(%{assigns: assigns} = socket, week_start) do
    with %{key: key, blocks: blocks} <- assigns[:series_weeks],
         true <- key == weeks_key(socket),
         %{days: days, at: at} <- Map.get(blocks, block_start(assigns, week_start)),
         true <- now_ms() - at < @weeks_ttl_ms do
      week_days(days, week_start)
    else
      _not_kept -> nil
    end
  end

  defp keep_block(socket, week, {:ok, {:ok, days}}) do
    key = weeks_key(socket)

    blocks =
      case socket.assigns[:series_weeks] do
        %{key: ^key, blocks: blocks} -> blocks
        _other -> %{}
      end

    entry = %{days: days, at: now_ms()}

    assign(socket, :series_weeks, %{
      key: key,
      blocks: Map.put(blocks, block_start(socket.assigns, week), entry)
    })
  end

  defp keep_block(socket, _week, _failed), do: socket

  defp week_days(days, week_start),
    do: Map.take(days, Enum.map(0..6, &Date.to_iso8601(Date.add(week_start, &1))))

  # The six weeks holding `week`, counted from the first session's week.
  defp block_start(assigns, week) do
    first = first_week(assigns, Series.first_start(assigns))
    Date.add(first, div(Date.diff(week, first), @block_days) * @block_days)
  end

  defp week_of(assigns, start),
    do: start |> DateTime.to_date() |> Date.beginning_of_week(assigns[:week_start] || :monday)

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp first_week(assigns, first) do
    first
    |> DateTime.to_date()
    |> Date.beginning_of_week(assigns[:week_start] || :monday)
  end

  defp slot_start(date, label, timezone) do
    with {:ok, clock} <- DateTimeUtils.parse_time_string(label),
         {:ok, start} <- DateTimeUtils.resolve_local(date, clock, timezone) do
      start
    else
      _unreadable -> nil
    end
  end

  defp window_until(assigns) do
    case Series.first_start(assigns) do
      nil -> nil
      first -> first |> DateTime.add(Check.span_days(), :day) |> DateTime.to_date()
    end
  end

  defp timezone(assigns), do: assigns[:user_timezone] || "Etc/UTC"
end
