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

  with wall-clock times in the organiser's zone (`BookablePayload`). A newer
  load replaces an older one: LiveView drops the answer of a task started
  under the same name before the latest. The last payload is kept in
  `:bookable` for the hook's `calendar:ready` reply.

  `SurfaceData.load_window/1` loads it with every window; the surface also
  reloads it when availability changes, and `LayerChoices` when the switch
  or the meeting type changes.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3, start_async: 3]

  alias Tymeslot.Availability
  alias Tymeslot.CalendarGrid.BookablePayload
  alias Tymeslot.CalendarGrid.LayerPreferences
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.Tasks
  alias TymeslotWeb.Dashboard.Calendar.Manipulation

  @type socket :: Phoenix.LiveView.Socket.t()

  # The most days `Availability.bookable_windows/4` answers at once.
  @max_days 42

  @doc """
  Loads the layer for the loaded window: computed off the process when it
  is on and has a meeting type, else pushed at once with no windows.
  """
  @spec load(socket()) :: socket()
  def load(socket) do
    %{preferences: preferences, bookable_types: types, current_user: user} = socket.assigns

    case {preferences.bookable_layer, LayerPreferences.meeting_type(preferences, types)} do
      {true, %{id: type_id}} ->
        range = range(socket.assigns)
        today = socket.assigns.today
        now = Clock.utc_now()

        start_async(
          socket,
          :bookable,
          Tasks.with_context(fn -> compute(user.id, type_id, range, today, now) end)
        )

      {on, type} ->
        push(socket, %{on: on, meeting_type: shown(type), windows: [], next: nil, error: false})
    end
  end

  @doc "Reads the meeting types again, then loads the layer."
  @spec reload(socket()) :: socket()
  def reload(socket) do
    socket
    |> assign(:bookable_types, LayerPreferences.meeting_types(socket.assigns.current_user.id))
    |> load()
  end

  @doc """
  The answer of a load. It is pushed only while the layer is still on with
  a meeting type; a load that raised or failed pushes `error: true`.
  """
  @spec loaded(socket(), {:ok, term()} | {:exit, term()}) :: socket()
  def loaded(socket, result) do
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

      {true, %{} = type, _failed} ->
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

  # The loaded window from today on, since nothing before now is bookable,
  # and at most @max_days long; nil when the whole window is in the past.
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
