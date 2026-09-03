defmodule TymeslotWeb.Dashboard.BookingsManagement.RequestActions do
  @moduledoc """
  Answering a booking request from the dashboard.

  The transition itself belongs to `Tymeslot.Meetings.Approval`, which is also
  what the emailed link calls; this module is only the dashboard's half of it.
  Two things live here rather than in the component:

    * **The ownership check.** The lookup is scoped to the signed-in host, so
      an id belonging to somebody else is not found rather than answered.

    * **Losing the race gracefully.** The host may have already answered in
      another tab, from the email, or the expiry sweep may have released the
      slot. None of those is an error to show as one, so the loser is told what
      actually happened and the list is reloaded.

  `reload` is passed in rather than imported so this module stays free of the
  component's loading pipeline; it is called after every outcome, including the
  failures, because the row on screen is stale either way.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [start_async: 3]

  require Logger

  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingState
  alias TymeslotWeb.Live.Shared.Flash

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc """
  Starts one approval action against a held request off the socket's process.

  `opts` carries the `:success` and `:failure` flash messages and the `:reload`
  function to refresh the list with. The transition itself, and its
  calendar/video/notification fan-out, runs inside `start_async/3` so
  `:answering_request` stays set across a render and the row's spinner and
  disabled state actually paint; `handle_answer/3` reports the outcome once
  the task completes.
  """
  @spec answer(socket(), map(), (map() -> {:ok, map()} | {:error, atom()}), keyword()) ::
          {:noreply, socket()}
  def answer(socket, params, action, opts) do
    case fetch_held_request(socket, params) do
      {:ok, meeting} -> {:noreply, start_answer(socket, meeting, action, opts)}
      {:error, message} -> {:noreply, finish(flash_and_stay(socket, message), opts)}
    end
  end

  # Keyed on the meeting id, never a bare atom: `start_async/3` called again
  # with a name already in flight silently drops the earlier task's result,
  # so two rows answered in overlapping windows would otherwise lose one
  # outcome. `opts` is stashed on the socket rather than threaded through the
  # async closure's return value, so a crash inside `action.(meeting)` still
  # leaves `handle_answer/3` able to report a proper failure and reload
  # instead of losing the reload function along with the crash.
  defp start_answer(socket, meeting, action, opts) do
    socket
    |> assign(:answering_request, meeting.id)
    |> assign(:answering_opts, Map.put(socket.assigns.answering_opts, meeting.id, opts))
    |> start_async({:answer_request, meeting.id}, fn -> action.(meeting) end)
  end

  @doc """
  Handles the result of the async task `answer/4` starts.

  `key` is the `{:answer_request, meeting_id}` name `start_async/3` was
  keyed on; `result` is the `handle_async/3` payload Phoenix wraps around the
  action's return value (`{:ok, action_result}` on completion, `{:exit,
  reason}` if the task itself crashed).

  The row on screen is reloaded on every outcome, including the failures and
  the crash, because it is stale either way — matching `answer/4`'s
  synchronous not-found/already-answered path.
  """
  @spec handle_answer(socket(), {:answer_request, Ecto.UUID.t()}, {:ok, term()} | {:exit, term()}) ::
          {:noreply, socket()}
  def handle_answer(socket, {:answer_request, meeting_id}, result) do
    {opts, socket} = pop_answer_opts(socket, meeting_id)

    {:noreply,
     socket
     |> apply_answer_result(meeting_id, result, opts)
     |> finish(opts)}
  end

  defp pop_answer_opts(socket, meeting_id) do
    {opts, remaining} = Map.pop(socket.assigns.answering_opts, meeting_id)
    {opts, assign(socket, :answering_opts, remaining)}
  end

  defp apply_answer_result(socket, _meeting_id, {:ok, {:ok, _answered}}, opts) do
    Flash.info(Keyword.fetch!(opts, :success))
    socket
  end

  defp apply_answer_result(socket, _meeting_id, {:ok, {:error, :not_awaiting_approval}}, _opts) do
    Flash.info(dgettext("dashboard_bookings", "That request had already been answered."))
    socket
  end

  defp apply_answer_result(socket, _meeting_id, {:ok, {:error, :meeting_started}}, _opts) do
    Flash.error(dgettext("dashboard_bookings", "That meeting's start time has already passed."))

    socket
  end

  defp apply_answer_result(socket, meeting_id, {:ok, {:error, reason}}, opts) do
    Logger.error("Failed to answer booking request from dashboard",
      meeting_id: meeting_id,
      reason: inspect(reason)
    )

    Flash.error(Keyword.fetch!(opts, :failure))
    socket
  end

  defp apply_answer_result(socket, meeting_id, {:exit, reason}, _opts) do
    Logger.error("Booking request answer task crashed",
      meeting_id: meeting_id,
      reason: inspect(reason)
    )

    Flash.error(dgettext("dashboard_bookings", "That request could not be answered."))
    socket
  end

  defp finish(socket, opts) do
    reload = Keyword.fetch!(opts, :reload)

    socket
    |> assign(:answering_request, nil)
    |> reload.()
  end

  @doc """
  Loads a request this host owns and has not yet answered.

  Deliberately not routed through the component's cancel/reschedule policy
  helper: those policies both accept a held request, so reusing them here would
  let a stale click answer a request that has already been resolved.

  The id is handed to `Meetings.get_meeting_for_organizer/2` unvalidated: it
  already casts and reports `{:error, :not_found}` on anything that is not a
  UUID, including a non-binary payload, so re-casting it here first would
  only be a second copy of that same check.
  """
  @spec fetch_held_request(socket(), map()) :: {:ok, map()} | {:error, String.t()}
  def fetch_held_request(socket, params) do
    case Meetings.get_meeting_for_organizer(
           Map.get(params, "id"),
           socket.assigns.current_user.id
         ) do
      {:ok, meeting} ->
        held_or_answered(meeting)

      _not_found ->
        {:error, dgettext("dashboard_bookings", "That request could not be found.")}
    end
  end

  defp held_or_answered(meeting) do
    if MeetingState.awaiting_approval?(meeting) do
      {:ok, meeting}
    else
      {:error, dgettext("dashboard_bookings", "That request had already been answered.")}
    end
  end

  @doc "Flashes a message and leaves the socket otherwise untouched."
  @spec flash_and_stay(socket(), String.t()) :: socket()
  def flash_and_stay(socket, message) do
    Flash.error(message)
    socket
  end
end
