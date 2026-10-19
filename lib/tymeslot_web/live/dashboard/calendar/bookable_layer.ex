defmodule TymeslotWeb.Dashboard.Calendar.BookableLayer do
  @moduledoc """
  The calendar surface's bookable-times layer: when guests can book the
  chosen meeting type, for the loaded window, drawn by the `CalendarCanvas`
  hook behind the events.

  The windows come from `Tymeslot.Availability.bookable_windows/4`, the
  booking page's own computation, so the two never disagree. It can reach
  the organiser's calendar providers, so it runs off the LiveView process
  (`start_async/3`, answered in `CalendarSurface.handle_async/3`) and its
  result is pushed as `calendar:bookable`:

      %{on, meeting_type: %{id, name} | nil, windows: [%{start, end}],
        next: %{at, label} | nil, error, timezone}

  with wall-clock times in the organiser's zone (`BookablePayload`). One
  load runs at a time (`:bookable_load`): a load asked for while another is
  in flight marks it `:stale`, and when it answers its result is dropped and
  exactly one fresh load starts, so a stale result is never pushed. A load
  in flight is never cancelled, since killing a task mid-query takes its
  database connection down with it. The last payload is kept in `:bookable`
  for the hook's `calendar:ready` reply.

  `SurfaceData.load_window/1` loads it with every window; the surface also
  reloads it when availability changes, and `LayerChoices` when the switch
  or the meeting type changes.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3, start_async: 3]

  require Logger

  alias Tymeslot.Availability
  alias Tymeslot.CalendarGrid.BookablePayload
  alias Tymeslot.CalendarGrid.LayerPreferences
  alias Tymeslot.CalendarGrid.Period
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Infrastructure.Tasks
  alias TymeslotWeb.Dashboard.Calendar.Manipulation

  @type socket :: Phoenix.LiveView.Socket.t()

  # The most days `Availability.bookable_windows/4` answers at once.
  @max_days 42

  @doc """
  Loads the layer for the loaded window: computed off the process when it
  is on and has a meeting type, else pushed at once with no windows. While
  a load is in flight it only marks that load stale; another starts once it
  answers. Month and agenda draw no bookable times, so there it neither
  computes nor pushes, and a load still running is marked stale so its
  answer is dropped; the next time view's window loads it again.
  """
  @spec load(socket()) :: socket()
  def load(socket) do
    cond do
      Period.time_grid?(socket.assigns.view) -> load_layer(socket)
      socket.assigns.bookable_load == :running -> assign(socket, :bookable_load, :stale)
      true -> socket
    end
  end

  defp load_layer(socket) do
    %{preferences: preferences, bookable_types: types} = socket.assigns

    case {preferences.bookable_layer, LayerPreferences.meeting_type(preferences, types),
          socket.assigns.bookable_load} do
      {true, %{}, :idle} ->
        start(socket)

      {true, %{}, _running_or_stale} ->
        assign(socket, :bookable_load, :stale)

      # A load still in flight now answers into a layer that is off or has
      # no meeting type, which drops its result, so no fresh one is needed.
      {on, type, load} ->
        socket
        |> assign(:bookable_load, if(load == :idle, do: :idle, else: :running))
        |> push(%{on: on, meeting_type: shown(type), windows: [], next: nil, error: false})
    end
  end

  defp start(socket) do
    %{preferences: preferences, bookable_types: types, current_user: user} = socket.assigns
    %{id: type_id} = LayerPreferences.meeting_type(preferences, types)
    range = range(socket.assigns)
    today = socket.assigns.today
    now = Clock.utc_now()

    socket
    |> assign(:bookable_load, :running)
    |> start_async(
      :bookable,
      Tasks.with_context(fn -> compute(user.id, type_id, range, today, now) end)
    )
  end

  @doc "Reads the meeting types again, then loads the layer."
  @spec reload(socket()) :: socket()
  def reload(socket) do
    socket
    |> assign(:bookable_types, LayerPreferences.meeting_types(socket.assigns.current_user.id))
    |> load()
  end

  @doc """
  The answer of a load. A stale one is dropped and the layer loads again;
  otherwise it is pushed only while the layer is still on with a meeting
  type, and a load that raised or failed pushes `error: true`.
  """
  @spec loaded(socket(), {:ok, term()} | {:exit, term()}) :: socket()
  def loaded(%{assigns: %{bookable_load: :stale}} = socket, _result),
    do: socket |> assign(:bookable_load, :idle) |> load()

  def loaded(socket, result) do
    socket = assign(socket, :bookable_load, :idle)
    %{preferences: preferences, bookable_types: types, timezone: timezone} = socket.assigns

    case {preferences.bookable_layer, LayerPreferences.meeting_type(preferences, types), result} do
      {true, %{} = type, {:ok, {:ok, windows, next}}} ->
        push(socket, %{
          on: true,
          meeting_type: shown(type),
          windows: BookablePayload.windows(windows, timezone),
          next: next_entry(socket, next),
          error: false
        })

      {true, %{} = type, failed} ->
        log_failure(socket, type, failed)
        push(socket, %{on: true, meeting_type: shown(type), windows: [], next: nil, error: true})

      _off_or_no_type ->
        socket
    end
  end

  # The windows of `range` and the first bookable start from now. When the
  # range starts today its first window starts at that time (bookable
  # windows begin at a bookable start); otherwise it is looked up.
  defp compute(user_id, type_id, range, today, now) do
    with {:ok, windows} <- windows(user_id, type_id, range),
         {:ok, next} <- next_start(user_id, type_id, windows, range, today, now) do
      {:ok, windows, next}
    end
  end

  defp windows(_user_id, _type_id, nil), do: {:ok, []}

  defp windows(user_id, type_id, %Date.Range{first: from, last: to}),
    do: Availability.bookable_windows(user_id, type_id, from, to)

  defp next_start(user_id, type_id, windows, range, today, now) do
    case {range, Enum.find(windows, &(DateTime.compare(&1.start_at, now) != :lt))} do
      {%Date.Range{first: ^today}, %{start_at: at}} -> {:ok, at}
      _otherwise -> Availability.next_bookable(user_id, type_id, now)
    end
  end

  defp log_failure(socket, type, failed) do
    reason =
      case failed do
        {:ok, {:error, reason}} -> reason
        {:exit, reason} -> {:exit, reason}
        other -> other
      end

    Logger.warning("Bookable layer failed to load",
      user_id: socket.assigns.current_user.id,
      meeting_type_id: type.id,
      reason: LogFormat.reason(reason)
    )
  end

  # The loaded window from today on, since nothing before now is bookable,
  # and at most @max_days long; nil when the whole window is in the past.
  # The longest time view is a week (loaded with a week either side), and
  # month and agenda never load the layer (`load/1`), so the clamp never bites.
  defp range(%{window: %Date.Range{first: first, last: last}, today: today}) do
    from = Enum.max([first, today], Date)

    if Date.compare(from, last) == :gt,
      do: nil,
      else: Date.range(from, Enum.min([last, Date.add(from, @max_days - 1)], Date))
  end

  # The hook needs the meeting type's id and name only.
  defp shown(nil), do: nil
  defp shown(type), do: Map.take(type, [:id, :name])

  defp next_entry(_socket, nil), do: nil

  defp next_entry(socket, at),
    do: %{
      at: BookablePayload.wall(at, socket.assigns.timezone),
      label: Manipulation.when_text(socket, at)
    }

  defp push(socket, payload) do
    payload = Map.put(payload, :timezone, socket.assigns.timezone)

    socket
    |> assign(:bookable, payload)
    |> push_event("calendar:bookable", payload)
  end
end
