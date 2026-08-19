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

  require Logger

  alias Ecto.UUID
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingState
  alias TymeslotWeb.Live.Shared.Flash

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc """
  Runs one approval action against a held request and reports the outcome.

  `opts` carries the `:success` and `:failure` flash messages and the `:reload`
  function to refresh the list with.
  """
  @spec answer(socket(), map(), (map() -> {:ok, map()} | {:error, atom()}), keyword()) ::
          {:noreply, socket()}
  def answer(socket, params, action, opts) do
    case fetch_held_request(socket, params) do
      {:ok, meeting} -> apply_answer(socket, meeting, action, opts)
      {:error, message} -> {:noreply, flash_and_stay(socket, message)}
    end
  end

  defp apply_answer(socket, meeting, action, opts) do
    socket = assign(socket, :answering_request, meeting.id)

    case action.(meeting) do
      {:ok, _answered} ->
        Flash.info(Keyword.fetch!(opts, :success))
        {:noreply, finish(socket, opts)}

      {:error, :not_awaiting_approval} ->
        Flash.info(dgettext("dashboard_bookings", "That request had already been answered."))
        {:noreply, finish(socket, opts)}

      {:error, :meeting_started} ->
        Flash.error(
          dgettext("dashboard_bookings", "That meeting's start time has already passed.")
        )

        {:noreply, finish(socket, opts)}

      {:error, reason} ->
        Logger.error("Failed to answer booking request from dashboard",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )

        Flash.error(Keyword.fetch!(opts, :failure))
        {:noreply, finish(socket, opts)}
    end
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
  """
  @spec fetch_held_request(socket(), map()) :: {:ok, map()} | {:error, String.t()}
  def fetch_held_request(socket, params) do
    with {:ok, validated_id} <- validate_meeting_id(params),
         {:ok, meeting} <-
           Meetings.get_meeting_for_user(validated_id, socket.assigns.current_user.email) do
      held_or_answered(meeting)
    else
      _not_found -> {:error, dgettext("dashboard_bookings", "That request could not be found.")}
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

  defp validate_meeting_id(params) do
    case Map.get(params, "id") do
      id when is_binary(id) -> UUID.cast(String.trim(id))
      _id -> :error
    end
  end
end
