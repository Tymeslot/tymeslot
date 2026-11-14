defmodule TymeslotWeb.Themes.Shared.Journey.Facts.Series do
  @moduledoc """
  The series: which sessions a booker books when the meeting type offers a
  series (`Tymeslot.MeetingTypes.SeriesSettings`), or, where the type also
  takes a single session, that they book just the one.

  The slot picked before it is the first session. A recurring series repeats
  it on the host's rhythm, and the booker sets how many sessions it has; a
  flexible series adds the sessions the booker picks from the type's offered
  times, after the first and within a year of it.

  Assigns:

    * `:series_choice`: nil before the moment opens, `:single` (only where a
      single session is allowed), or `%{mode: :recurring | :flexible, starts:
      [DateTime.t()], count: pos_integer()}`; a recurring choice holds only
      its first start;
    * `:series_preview`: the `Occurrence`s the last check judged, or nil;
      `:series_preview_key` names the choice they answer;
    * `:series_checking?`: whether a check is in flight;
    * `:series_refocus`: whether the moment should take the focus back
      to where the booker adds sessions, set once one was added;
    * `:series_error`: why the last check gave no answer
      (`:availability_unverifiable`, `:overlapping_starts`, `:invalid_count`),
      or nil;
    * `:series_picker`: a flexible series' picker of further sessions, nil
      while closed (`TymeslotWeb.Themes.Shared.SeriesPicker`);
    * `:series_offered?` and `:series_single_allowed?`: the meeting type's
      offer, settled once per meeting type when the page assigns it
      (`assign_offer/2`), since each costs a subscription query on the
      managed plan; the fact reads them and never asks again;
    * `:series` and `:series_meetings`: the series a submission booked,
      forgotten by `clear/1` and by every new submission (`forget_booked/1`).

  Needed when the type's series is offered, the booking is not a reschedule
  (which moves one session) and the journey has a moment asking it; a
  journey without one books single sessions. Known once the booker chose a
  single session, or a series whose last check found every session
  available.

  Every change to the choice checks it again with
  `Tymeslot.BookingSeries.preview/3` in a `start_async/3` task under
  `:series_preview`, cancelling the one in flight first, and the result is
  applied only when it answers the choice still on screen
  (`handle_async/3`). Changing the slot forgets the choice (`clear/1`, and on
  a paged journey `enter/2` finding a different first session).
  """

  use TymeslotWeb.Themes.Shared.Journey.Fact

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [cancel_async: 2, start_async: 3]

  alias Phoenix.LiveView.Socket
  alias Tymeslot.BookingSeries
  alias Tymeslot.BookingSeries.Occurrence
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.MeetingTypes.SeriesSettings
  alias Tymeslot.Utils.DateTimeUtils
  alias TymeslotWeb.Live.Scheduling.AvailabilityHelpers
  alias TymeslotWeb.Themes.Shared.Journey.Fact
  alias TymeslotWeb.Themes.Shared.Journey.Progress
  alias TymeslotWeb.Themes.Shared.Journey.Runtime
  alias TymeslotWeb.Themes.Shared.SeriesPicker

  require Logger

  @type choice ::
          nil
          | :single
          | %{mode: :recurring | :flexible, starts: [DateTime.t()], count: pos_integer()}

  @events [
    :series_set_count,
    :series_single,
    :series_as_series,
    :series_add_start,
    :series_remove_start,
    :series_retry,
    :series_picker_open,
    :series_picker_close,
    :series_picker_week,
    :series_picker_day,
    :series_picker_retry
  ]

  @impl Fact
  def key, do: :series

  @impl Fact
  def requires(_assigns), do: [:slot]

  @impl Fact
  def required?(assigns) do
    assigns[:series_offered?] == true and is_nil(assigns[:reschedule_meeting_uid]) and
      is_nil(assigns[:reschedule_seat_token]) and asked?(assigns)
  end

  @impl Fact
  def known?(assigns) do
    case assigns[:series_choice] do
      :single -> assigns[:series_single_allowed?] == true
      %{} = choice -> checked_available?(assigns, choice)
      nil -> false
    end
  end

  @impl Fact
  def events, do: @events

  @impl Fact
  def handle(socket, :series_set_count, value), do: {:noreply, set_count(socket, value)}

  def handle(socket, :series_single, _data) do
    if socket.assigns[:series_single_allowed?] == true,
      do:
        {:noreply, socket |> cancel_check() |> assign(series_choice: :single, series_error: nil)},
      else: {:noreply, socket}
  end

  def handle(socket, :series_as_series, _data),
    do: {:noreply, socket |> assign(:series_choice, nil) |> choose_default()}

  def handle(socket, :series_add_start, value), do: {:noreply, add_start(socket, value)}
  def handle(socket, :series_remove_start, value), do: {:noreply, remove_start(socket, value)}
  def handle(socket, :series_retry, _data), do: {:noreply, check(socket)}
  def handle(socket, :series_picker_open, _data), do: {:noreply, SeriesPicker.open(socket)}
  def handle(socket, :series_picker_close, _data), do: {:noreply, SeriesPicker.close(socket)}
  def handle(socket, :series_picker_week, dir), do: {:noreply, SeriesPicker.move(socket, dir)}
  def handle(socket, :series_picker_day, iso), do: {:noreply, SeriesPicker.pick_day(socket, iso)}
  def handle(socket, :series_picker_retry, _data), do: {:noreply, SeriesPicker.retry(socket)}

  # A choice for another first session (the booker went back and picked
  # another time) is made again from the new one.
  @impl Fact
  def enter(socket, _params) do
    case {socket.assigns[:series_choice], first_start(socket.assigns)} do
      {_choice, nil} -> socket
      {:single, _first} -> socket
      {%{starts: [first | _rest]}, first} -> socket
      _no_or_stale_choice -> choose_default(socket)
    end
  end

  @impl Fact
  def continue(socket) do
    cond do
      known?(socket.assigns) -> {:done, socket}
      (lost = unavailable(socket.assigns)) != [] -> {:error, {:occurrences_unavailable, lost}}
      true -> {:error, :series_required}
    end
  end

  # The series a booking made goes too: a later booking is a booking of its
  # own, single or series.
  @impl Fact
  def clear(socket) do
    socket
    |> cancel_check()
    |> assign(
      series_choice: nil,
      series_preview: nil,
      series_preview_key: nil,
      series_checking?: false,
      series_error: nil,
      series_picker: nil,
      series_refocus: false
    )
    |> forget_booked()
  end

  @doc """
  Forgets the series a submission booked (`:series`, `:series_meetings`):
  every submission starts without one, so its confirmation shows only what
  it booked.
  """
  @spec forget_booked(Socket.t()) :: Socket.t()
  def forget_booked(socket), do: assign(socket, series: nil, series_meetings: [])

  @doc "What a page holds before the moment opens."
  @spec assign_defaults(Socket.t()) :: Socket.t()
  def assign_defaults(socket) do
    assign(socket,
      series_choice: nil,
      series_preview: nil,
      series_preview_key: nil,
      series_checking?: false,
      series_error: nil,
      series_picker: nil,
      series_refocus: false,
      series: nil,
      series_meetings: [],
      series_offered?: false,
      series_single_allowed?: true,
      series_offer_type_id: nil
    )
  end

  @doc """
  Settles whether `meeting_type`'s series is offered and whether it takes a
  single session (`SeriesSettings.offer/1`), once per meeting type: the same
  type assigned again keeps what was settled.
  """
  @spec assign_offer(Socket.t(), map()) :: Socket.t()
  def assign_offer(socket, meeting_type) do
    id = Map.get(meeting_type, :id)

    if id != nil and socket.assigns[:series_offer_type_id] == id do
      socket
    else
      %{offered?: offered, single_allowed?: single} = offer(meeting_type)

      assign(socket,
        series_offered?: offered,
        series_single_allowed?: single,
        series_offer_type_id: id
      )
    end
  end

  # A demo organiser's types are plain maps and offer no series.
  defp offer(%MeetingTypeSchema{series_mode: mode} = meeting_type) when mode != nil,
    do: SeriesSettings.offer(meeting_type)

  defp offer(_meeting_type), do: %{offered?: false, single_allowed?: true}

  @doc """
  The series a submission asks for (`meeting_params.series`), or nil for a
  single session: a booking that does not need the fact, or whose booker
  chose one session.
  """
  @spec request(map()) :: map() | nil
  def request(assigns) do
    case {required?(assigns), assigns[:series_choice]} do
      {true, %{mode: :recurring, starts: [first | _rest], count: count}} ->
        %{mode: :recurring, first_start: first, count: count}

      {true, %{mode: :flexible, starts: starts}} ->
        %{mode: :flexible, starts: starts}

      _single ->
        nil
    end
  end

  @doc "The number of sessions chosen, or nil when the booking is a single session."
  @spec count(map()) :: pos_integer() | nil
  def count(assigns) do
    if request(assigns), do: assigns.series_choice.count
  end

  @doc """
  The first session, the slot picked: the chosen day and time in the
  booker's timezone, or nil while either is missing.
  """
  @spec first_start(map()) :: DateTime.t() | nil
  def first_start(assigns) do
    with date when is_binary(date) <- assigns[:selected_date],
         time when is_binary(time) <- assigns[:selected_time],
         {:ok, day} <- Date.from_iso8601(date),
         {:ok, clock} <- DateTimeUtils.parse_time_string(time),
         {:ok, start} <- DateTimeUtils.resolve_local(day, clock, timezone(assigns)) do
      start
    else
      _incomplete -> nil
    end
  end

  @doc """
  The sessions to show, in order, as `%{position, start, status}`: the
  status the last check gave for the choice on screen, else `:pending`
  (not checked yet, or a flexible series with fewer sessions than it needs).
  """
  @spec rows(map()) :: [%{position: pos_integer(), start: DateTime.t(), status: term()}]
  def rows(%{series_choice: %{} = choice} = assigns) do
    if preview_answers?(assigns, choice) do
      Enum.map(
        assigns.series_preview,
        &%{position: &1.position, start: &1.start, status: &1.status}
      )
    else
      choice
      |> planned_starts(assigns)
      |> Enum.with_index(1)
      |> Enum.map(fn {start, position} ->
        %{position: position, start: start, status: :pending}
      end)
    end
  end

  def rows(_assigns), do: []

  @doc "The sessions the last check found unavailable for the choice on screen."
  @spec unavailable(map()) :: [Occurrence.t()]
  def unavailable(%{series_choice: %{} = choice} = assigns) do
    if preview_answers?(assigns, choice),
      do: Enum.filter(assigns.series_preview, &match?({:unavailable, _reason}, &1.status)),
      else: []
  end

  def unavailable(_assigns), do: []

  @doc """
  After a submission found sessions taken: `occurrences` (the ones it lost)
  are laid over the sessions on screen by position, so the moment names
  them beside the rest, and the series is checked again. A session the
  last check had not judged stays `:pending` until that check answers.
  """
  @spec merge_lost(Socket.t(), [Occurrence.t()]) :: Socket.t()
  def merge_lost(%{assigns: %{series_choice: %{} = choice}} = socket, occurrences) do
    lost = Map.new(occurrences, &{&1.position, &1})

    preview =
      if preview_answers?(socket.assigns, choice),
        do: Enum.map(socket.assigns.series_preview, &Map.get(lost, &1.position, &1)),
        else: lay_over_rows(rows(socket.assigns), lost)

    socket
    |> assign(series_preview: preview, series_preview_key: key(choice))
    |> check()
  end

  def merge_lost(socket, _occurrences), do: socket

  # The rows on screen with each lost session in its place, and a lost
  # session the rows do not reach yet (a recurring series before its check
  # planned the rest) added in order.
  defp lay_over_rows(rows, lost) do
    shown = Map.new(rows, &{&1.position, unjudged(&1)})

    shown
    |> Map.merge(lost)
    |> Map.values()
    |> Enum.sort_by(& &1.position)
  end

  defp unjudged(row),
    do: %Occurrence{position: row.position, start: row.start, end: row.start, status: :pending}

  @doc """
  A `start_async/3` result: `:series_preview` (a check) or `{:series_week,
  week_start}` (the picker's week); `:unhandled` for any other name.
  """
  @spec handle_async(term(), term(), Socket.t()) :: {:noreply, Socket.t()} | :unhandled
  def handle_async(:series_preview, {:ok, {key, result}}, socket) do
    if socket.assigns[:series_checking?] and key == current_key(socket.assigns),
      do: {:noreply, socket |> apply_check(key, result) |> Runtime.settle()},
      else: {:noreply, socket}
  end

  # A cancelled check is replaced by the one cancelling it.
  def handle_async(:series_preview, {:exit, {:shutdown, :cancel}}, socket), do: {:noreply, socket}

  def handle_async(:series_preview, {:exit, reason}, socket) do
    Logger.warning("Series check failed", reason: LogFormat.reason(reason))

    {:noreply, assign(socket, series_checking?: false, series_error: :availability_unverifiable)}
  end

  def handle_async({:series_week, _week} = name, result, socket),
    do: SeriesPicker.handle_async(name, result, socket)

  def handle_async(_name, _result, _socket), do: :unhandled

  # Choosing

  defp choose_default(socket) do
    case {first_start(socket.assigns), socket.assigns[:meeting_type]} do
      {%DateTime{} = first, %{series_mode: :recurring, series_min_occurrences: min}} ->
        socket
        |> assign(series_choice: %{mode: :recurring, starts: [first], count: min})
        |> assign(series_picker: nil)
        |> check()

      {%DateTime{} = first, %{series_mode: :flexible}} ->
        socket
        |> assign(series_choice: %{mode: :flexible, starts: [first], count: 1})
        |> assign(series_picker: nil)
        |> check()

      _no_first_or_series ->
        socket
    end
  end

  defp set_count(%{assigns: %{series_choice: %{mode: :recurring} = choice}} = socket, value) do
    with {count, ""} <- parse_integer(value),
         true <- count in SeriesSettings.count_range(socket.assigns.meeting_type),
         true <- count != choice.count do
      socket |> assign(:series_choice, %{choice | count: count}) |> check()
    else
      _invalid_or_same -> socket
    end
  end

  defp set_count(socket, _value), do: socket

  defp parse_integer(value) when is_integer(value), do: {value, ""}
  defp parse_integer(value) when is_binary(value), do: Integer.parse(value)
  defp parse_integer(_value), do: :error

  # Only a session the picker offers is taken: the payload is visitor input.
  defp add_start(%{assigns: %{series_choice: %{mode: :flexible} = choice}} = socket, value)
       when is_binary(value) do
    max = socket.assigns.meeting_type.series_max_occurrences

    with {:ok, start, _offset} <- DateTime.from_iso8601(value),
         true <- choice.count < max,
         %{start: offered} <- SeriesPicker.offered(socket.assigns, start) do
      starts = Enum.sort([offered | choice.starts], DateTime)

      socket
      |> assign(:series_choice, %{choice | starts: starts, count: length(starts)})
      |> assign(series_picker: nil, series_refocus: true)
      |> check()
    else
      _not_offered -> socket
    end
  end

  defp add_start(socket, _value), do: socket

  # The first session is the slot picked and is never removed here.
  defp remove_start(
         %{assigns: %{series_choice: %{mode: :flexible, starts: [first | rest]} = choice}} =
           socket,
         value
       )
       when is_binary(value) do
    with {:ok, start, _offset} <- DateTime.from_iso8601(value),
         kept = Enum.reject(rest, &(DateTime.compare(&1, start) == :eq)),
         true <- length(kept) < length(rest) do
      starts = [first | kept]

      socket
      |> assign(:series_choice, %{choice | starts: starts, count: length(starts)})
      |> assign(:series_refocus, false)
      |> check()
    else
      _not_chosen -> socket
    end
  end

  defp remove_start(socket, _value), do: socket

  # Checking

  # Runs the check for the choice on screen, cancelling one in flight. A
  # flexible series with fewer sessions than the type needs is not checked
  # yet: nothing could book it.
  defp check(%{assigns: %{series_choice: %{} = choice}} = socket) do
    socket = cancel_check(socket)

    if checkable?(socket.assigns, choice) do
      key = key(choice)
      meeting_type = socket.assigns.meeting_type
      first_or_starts = if choice.mode == :recurring, do: hd(choice.starts), else: choice.starts

      # Strict, as the booking is: a calendar out of reach is said to be,
      # rather than read as free and refused only on submit.
      opts = [
        count: choice.count,
        booker_tz: timezone(socket.assigns),
        duration_minutes: AvailabilityHelpers.duration_minutes(socket),
        strict_calendar: true
      ]

      socket
      |> assign(series_checking?: true, series_error: nil)
      |> start_async(
        :series_preview,
        Tasks.with_context(fn ->
          {key, BookingSeries.preview(meeting_type, first_or_starts, opts)}
        end)
      )
    else
      assign(socket, series_checking?: false, series_error: nil)
    end
  end

  defp check(socket), do: socket

  defp cancel_check(socket) do
    if socket.assigns[:series_checking?],
      do: socket |> cancel_async(:series_preview) |> assign(:series_checking?, false),
      else: socket
  end

  defp checkable?(_assigns, %{mode: :recurring}), do: true

  defp checkable?(assigns, %{mode: :flexible, count: count}),
    do: count >= assigns.meeting_type.series_min_occurrences

  defp apply_check(socket, key, {:ok, occurrences}),
    do:
      assign(socket,
        series_preview: occurrences,
        series_preview_key: key,
        series_checking?: false,
        series_error: nil
      )

  defp apply_check(socket, _key, {:error, reason}),
    do: assign(socket, series_checking?: false, series_error: reason)

  @doc """
  What names a choice's check: `:series_preview_key` holds the key of the
  choice the preview on screen answers.
  """
  @spec key(map()) :: tuple()
  def key(%{mode: :recurring, starts: [first | _rest], count: count}),
    do: {:recurring, first, count}

  def key(%{mode: :flexible, starts: starts}), do: {:flexible, starts}

  defp current_key(%{series_choice: %{} = choice}), do: key(choice)
  defp current_key(_assigns), do: nil

  defp preview_answers?(assigns, choice),
    do: is_list(assigns[:series_preview]) and assigns[:series_preview_key] == key(choice)

  defp checked_available?(assigns, choice) do
    not assigns[:series_checking?] and preview_answers?(assigns, choice) and
      checkable?(assigns, choice) and
      Enum.all?(assigns.series_preview, &(&1.status == :available))
  end

  # Before a check answers, a recurring series lists its first session only;
  # the check plans the rest.
  defp planned_starts(%{starts: starts}, _assigns), do: starts

  defp timezone(assigns), do: assigns[:user_timezone] || "Etc/UTC"

  defp asked?(%{journey: %{moments: _moments} = journey}),
    do: Progress.moment_for(journey, :series) != nil

  defp asked?(_assigns), do: false
end
