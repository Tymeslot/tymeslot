defmodule TymeslotWeb.Dashboard.Calendar.BlockTime do
  @moduledoc """
  "Block this time" from the bookable layer's explainer, and its undo.

  The hook sends the labelled window's wall-clock start and end
  (`calendar:block`). They are read in the organiser's zone and checked by
  the rule the block itself applies (`Changes.check_block_span/2`: a real
  span of at most a week that has not ended), within the edit rate limit. The block itself (`Tymeslot.CalendarGrid.Changes.block_time/4`: an
  event that blocks availability on the default calendar, or a part-day
  time off without one) can reach a calendar provider, so it runs off the
  LiveView process under the name `{:block, n}`; the reply only says it was
  accepted. Its answer (`CalendarSurface.handle_async/3`) puts the change on
  the undo stack as `%{kind: :block, key: {:block, n}, id: nil, result:
  result}`, names it in a toast with Undo, and reloads the window, which
  reloads the bookable layer without the blocked time. Undo calls
  `Changes.unblock_time/2` the same way, under `{:unblock, n}`.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [start_async: 3]

  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.CalendarGrid.EditGuard
  alias Tymeslot.CalendarGrid.Moves
  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.Utils.DateTimeUtils.TimeFormat
  alias TymeslotWeb.Dashboard.Calendar.Manipulation
  alias TymeslotWeb.Dashboard.Calendar.SurfaceData
  alias TymeslotWeb.Dashboard.Calendar.Toast
  alias TymeslotWeb.Dashboard.Calendar.UndoStack
  alias TymeslotWeb.Live.Shared.Flash

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc """
  Checks the window the hook sent and starts blocking it. Answers the
  hook's reply: `%{accepted: true}`, or `%{accepted: false, error: message}`.
  """
  @spec start(socket(), map()) :: {map(), socket()}
  def start(socket, %{"start" => start, "end" => finish})
      when is_binary(start) and is_binary(finish) do
    %{current_user: %{id: user_id}, timezone: timezone} = socket.assigns

    with {:ok, start_at} <- Moves.wall_to_utc(start, timezone),
         {:ok, end_at} <- Moves.wall_to_utc(finish, timezone),
         :ok <- Changes.check_block_span(start_at, end_at),
         :ok <- EditGuard.rate_limit(user_id) do
      key = {:block, System.unique_integer([:positive])}
      title = dgettext("dashboard_calendar_booking", "Blocked")

      socket =
        start_async(
          socket,
          key,
          Tasks.with_context(fn ->
            {start_at, end_at, Changes.block_time(user_id, start_at, end_at, title)}
          end)
        )

      {%{accepted: true}, socket}
    else
      {:error, :rate_limited, message} -> {%{accepted: false, error: message}, socket}
      {:error, reason} when reason in [:in_past, :too_long] -> {refused(reason), socket}
      _invalid -> {refused(), socket}
    end
  end

  def start(socket, _params), do: {refused(), socket}

  @doc "The block's answer: on the undo stack with a toast, or a flash saying why not."
  @spec blocked(socket(), {:block, pos_integer()}, {:ok, term()} | {:exit, term()}) :: socket()
  def blocked(socket, key, {:ok, {start_at, end_at, {:ok, result}}}) do
    entry = %{kind: :block, key: key, id: nil, result: result}

    socket
    |> assign(:undo, UndoStack.push(socket.assigns.undo, entry))
    |> Toast.show(blocked_text(socket, start_at, end_at), undo: true, key: key)
    |> SurfaceData.reload(:events)
  end

  # The provider took the write but the event is not cached yet: there is no
  # result to undo, and the next sync brings it in.
  def blocked(socket, _key, {:ok, {_start_at, _end_at, {:error, :not_cached}}}) do
    socket
    |> Toast.show(
      dgettext(
        "dashboard_calendar_booking",
        "Blocked. It may take a moment to show on your calendar."
      )
    )
    |> SurfaceData.reload(:events)
  end

  # The calendar was unreachable: nothing is blocked yet, the busy event is
  # written at the next sync, so there is no result to undo and nothing to retry.
  def blocked(socket, _key, {:ok, {_start_at, _end_at, {:error, {:queued, _reason}}}}),
    do:
      Toast.show(
        socket,
        dgettext(
          "dashboard_calendar_booking",
          "Saved. It will block this time once your calendar is reachable again."
        )
      )

  def blocked(socket, _key, {:ok, {_start_at, _end_at, {:error, reason}}}),
    do: Flash.put_flash(socket, :error, refusal(reason))

  def blocked(socket, _key, {:exit, _reason}),
    do: Flash.put_flash(socket, :error, refusal(:failed))

  @doc "Undoes a block (an undo entry of kind `:block`)."
  @spec undo(socket(), map()) :: socket()
  def undo(socket, %{kind: :block, key: {:block, n}, result: result} = entry) do
    user_id = socket.assigns.current_user.id

    start_async(
      socket,
      {:unblock, n},
      Tasks.with_context(fn -> {entry, Changes.unblock_time(user_id, result)} end)
    )
  end

  @doc """
  The undo's answer. A failed undo goes back on the stack so Ctrl Z can try
  again, unless the block is already gone or has been moved or renamed
  since.
  """
  @spec unblocked(socket(), {:ok, term()} | {:exit, term()}) :: socket()
  def unblocked(socket, {:ok, {_entry, :ok}}) do
    socket
    |> Toast.show(
      dgettext("dashboard_calendar_booking", "Unblocked. Guests can book this time again.")
    )
    |> SurfaceData.reload(:events)
  end

  def unblocked(socket, {:ok, {_entry, {:error, {:queued, _reason}}}}),
    do:
      Toast.show(
        socket,
        dgettext(
          "dashboard_calendar_booking",
          "Saved. The time will free up once your calendar is reachable again."
        )
      )

  def unblocked(socket, {:ok, {_entry, {:error, :changed}}}),
    do:
      Toast.show(
        socket,
        dgettext(
          "dashboard_calendar_booking",
          "Couldn't undo the block. It has been moved or renamed since."
        )
      )

  def unblocked(socket, {:ok, {_entry, {:error, :not_found}}}),
    do:
      Toast.show(socket, dgettext("dashboard_calendar", "That change can't be undone any more."))

  def unblocked(socket, {:ok, {entry, {:error, _reason}}}) do
    socket
    |> assign(:undo, UndoStack.push(socket.assigns.undo, entry))
    |> Flash.put_flash(:error, undo_failed())
  end

  def unblocked(socket, {:exit, _reason}), do: Flash.put_flash(socket, :error, undo_failed())

  defp blocked_text(socket, start_at, end_at) do
    finish =
      end_at
      |> DateTime.shift_zone!(socket.assigns.timezone)
      |> DateTime.to_time()
      |> TimeFormat.format(socket.assigns.time_format)

    dgettext(
      "dashboard_calendar_booking",
      "Blocked %{when} to %{finish}. Guests can't book this time.",
      when: Manipulation.when_text(socket, start_at),
      finish: finish
    )
  end

  defp refused,
    do: %{
      accepted: false,
      error: dgettext("dashboard_calendar_booking", "That time can't be blocked.")
    }

  defp refused(reason), do: %{accepted: false, error: refusal(reason)}

  defp refusal(:limit_reached),
    do:
      dgettext(
        "dashboard_calendar_booking",
        "You have too many time-off periods to block more time. Remove some first."
      )

  defp refusal(:too_far),
    do: dgettext("dashboard_calendar_booking", "That's too far ahead to block.")

  defp refusal(:too_long),
    do: dgettext("dashboard_calendar_booking", "You can block at most a week at a time.")

  defp refusal(:in_past),
    do: dgettext("dashboard_calendar_booking", "That time has already passed.")

  defp refusal(_reason),
    do: dgettext("dashboard_calendar_booking", "Couldn't block that time. Please try again.")

  defp undo_failed,
    do: dgettext("dashboard_calendar_booking", "Couldn't undo the block. Please try again.")
end
