defmodule TymeslotWeb.Themes.Shared.Journey.Facts.Series.Preview do
  @moduledoc """
  Checking the series choice on screen (`Journey.Facts.Series`): every
  change to it checks it again with `Tymeslot.BookingSeries.preview/3` in a
  `start_async/3` task under `:series_preview`, cancelling the one in
  flight first, and the answer is applied only when it answers the choice
  still on screen (`handle_async/2`).

  Each check, and each week the flexible picker fetches, reads the host's
  calendars afresh over the whole series, so every one is charged to the
  visitor's address (`charge_read/1`, the `:booking_series_check` limit);
  past it, the check is not run and the moment says so with a retry
  (`series_error: :rate_limited`). The submission's own check is fresh
  and strict whatever this limit says.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [cancel_async: 2, connected?: 1, start_async: 3]

  alias Phoenix.LiveView.Socket
  alias Tymeslot.BookingSeries
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Helpers.ClientIP
  alias TymeslotWeb.Live.Scheduling.AvailabilityHelpers
  alias TymeslotWeb.Themes.Shared.Journey.Facts.Series
  alias TymeslotWeb.Themes.Shared.Journey.Facts.Series.CarriedChoice
  alias TymeslotWeb.Themes.Shared.Journey.Runtime

  require Logger

  @doc """
  What names a choice's check: `:series_preview_key` holds the key of the
  choice the preview on screen answers.
  """
  @spec key(map()) :: tuple()
  def key(%{mode: :recurring, starts: [first | _rest], count: count}),
    do: {:recurring, first, count}

  def key(%{mode: :flexible, starts: starts}), do: {:flexible, starts}

  @doc "Whether the preview on screen answers `choice`."
  @spec answers?(map(), map()) :: boolean()
  def answers?(assigns, choice),
    do: is_list(assigns[:series_preview]) and assigns[:series_preview_key] == key(choice)

  @doc """
  Whether `choice` can be checked: a flexible series with fewer sessions
  than the type needs is not checked yet, since nothing could book it.
  """
  @spec checkable?(map(), map()) :: boolean()
  def checkable?(_assigns, %{mode: :recurring}), do: true

  def checkable?(assigns, %{mode: :flexible, count: count}),
    do: count >= assigns.meeting_type.series_min_occurrences

  @doc """
  Charges one fresh read of the host's calendars to the visitor's address
  (`:booking_series_check`): `:ok`, or `{:error, :rate_limited}` past the
  limit. A page not yet connected reads nothing (`start_async/3` waits for
  the connection) and is not charged.
  """
  @spec charge_read(Socket.t()) :: :ok | {:error, :rate_limited}
  def charge_read(socket) do
    if connected?(socket) do
      case RateLimiter.check(:booking_series_check, ClientIP.get(socket)) do
        :ok -> :ok
        _refused -> {:error, :rate_limited}
      end
    else
      :ok
    end
  end

  @doc """
  The booker changed the choice to `choice`: it is checked again, and a
  choice known before the change stays known while that check runs
  (`Series.rechecking?/1`).
  """
  @spec recheck(Socket.t(), map()) :: Socket.t()
  def recheck(socket, choice) do
    was_known = Series.known?(socket.assigns)

    socket = socket |> assign(:series_choice, choice) |> check()
    assign(socket, :series_rechecking?, was_known and socket.assigns.series_checking?)
  end

  @doc """
  Runs the check for the choice on screen, cancelling one started before,
  even one no longer waited for (`Series.clear/1`).
  """
  @spec check(Socket.t()) :: Socket.t()
  def check(%{assigns: %{series_choice: %{} = choice}} = socket) do
    socket =
      socket
      |> cancel_async(:series_preview)
      |> assign(series_checking?: false, series_rechecking?: false)

    if checkable?(socket.assigns, choice),
      do: start_check(socket, choice),
      else: assign(socket, series_checking?: false, series_error: nil)
  end

  def check(socket), do: socket

  defp start_check(socket, choice) do
    key = key(choice)
    meeting_type = socket.assigns.meeting_type
    first_or_starts = if choice.mode == :recurring, do: hd(choice.starts), else: choice.starts

    # Strict, as the booking is: a calendar out of reach is said to be,
    # rather than read as free and refused only on submit.
    opts = [
      count: choice.count,
      booker_tz: socket.assigns[:user_timezone] || "Etc/UTC",
      duration_minutes: AvailabilityHelpers.duration_minutes(socket),
      strict_calendar: true
    ]

    case charge_read(socket) do
      :ok ->
        socket
        |> assign(series_checking?: true, series_error: nil)
        |> start_async(
          :series_preview,
          Tasks.with_context(fn ->
            {key, BookingSeries.preview(meeting_type, first_or_starts, opts)}
          end)
        )

      {:error, :rate_limited} ->
        assign(socket, series_checking?: false, series_error: :rate_limited)
    end
  end

  @doc "Stops waiting for a check in flight, cancelling it."
  @spec cancel(Socket.t()) :: Socket.t()
  def cancel(socket) do
    if socket.assigns[:series_checking?],
      do:
        socket
        |> cancel_async(:series_preview)
        |> assign(series_checking?: false, series_rechecking?: false),
      else: socket
  end

  @doc """
  A check's `start_async/3` result. Applied, it enters what waited on the
  series on the same moment (the details beside it, `Runtime.enter_ready/1`)
  and lets the navigator settle.
  """
  @spec handle_async(term(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_async({:ok, {key, result}}, socket) do
    if socket.assigns[:series_checking?] and key == current_key(socket.assigns),
      do: {:noreply, socket |> apply_check(key, result) |> settle()},
      else: {:noreply, socket}
  end

  # A cancelled check is replaced by the one cancelling it.
  def handle_async({:exit, {:shutdown, :cancel}}, socket), do: {:noreply, socket}

  # A check no longer waited for (forgotten by `clear/1`) changes nothing
  # when it fails.
  def handle_async({:exit, reason}, socket) do
    if socket.assigns[:series_checking?] do
      Logger.warning("Series check failed", reason: LogFormat.reason(reason))

      {:noreply,
       socket
       |> assign(
         series_checking?: false,
         series_rechecking?: false,
         series_error: :availability_unverifiable
       )
       |> settle()}
    else
      {:noreply, socket}
    end
  end

  defp current_key(%{series_choice: %{} = choice}), do: key(choice)
  defp current_key(_assigns), do: nil

  defp apply_check(socket, key, {:ok, occurrences}) do
    {socket, key, occurrences} = CarriedChoice.drop_lost(socket, key, occurrences)

    assign(socket,
      series_preview: occurrences,
      series_preview_key: key,
      series_checking?: false,
      series_rechecking?: false,
      series_error: nil,
      series_restoring: nil
    )
  end

  defp apply_check(socket, _key, {:error, reason}),
    do:
      assign(socket,
        series_checking?: false,
        series_rechecking?: false,
        series_error: reason,
        series_restoring: nil
      )

  # What the answer changes on the page: the facts waiting on the series are
  # entered and the navigator settles. A moment the answer makes current
  # takes no focus: the booker is still at the control that asked.
  defp settle(socket) do
    before = socket.assigns[:current_state]
    socket = socket |> Runtime.enter_ready() |> Runtime.settle()

    if socket.assigns[:current_state] != before,
      do: assign(socket, :journey_focus, nil),
      else: socket
  end
end
