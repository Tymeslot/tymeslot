defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.OfferedTimeHandlers do
  @moduledoc """
  Event handling for a one-to-one type's offered times in the meeting-type
  form (`MeetingTypeForm.FixedDatesSection`): adding a time and removing
  one.

  The times are `Tymeslot.MeetingTypes.OfferedTimes` rows, read fresh after
  every change rather than kept in the form's own state. They are entered
  and shown in the host's own time zone, as a group type's planned dates
  are (`SessionHandlers`, which also assigns that zone).
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.Component
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.OfferedTimes
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.SessionHandlers

  @doc "Assigns the type's offered times and the input row's state."
  @spec assign_offered_times(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_offered_times(socket) do
    socket
    |> Component.assign(:offered_time_rows, rows(socket.assigns[:type]))
    |> Component.assign_new(:new_offered_time, fn -> %{} end)
    |> Component.assign_new(:offered_time_error, fn -> nil end)
  end

  @doc "The form's events for offered times, by name; `MeetingTypeForm` hands each here."
  @spec events() :: [String.t()]
  def events, do: ~w(update_offered_time_input add_offered_time remove_offered_time)

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          Phoenix.LiveView.Socket.t()
  def handle_event("update_offered_time_input", %{"offered_time" => params}, socket)
      when is_map(params) do
    Component.assign(socket,
      new_offered_time:
        Map.merge(socket.assigns[:new_offered_time] || %{}, Map.take(params, ~w(date time))),
      offered_time_error: nil
    )
  end

  def handle_event("add_offered_time", _params, socket), do: add(socket)
  def handle_event("remove_offered_time", %{"id" => id}, socket), do: remove(id, socket)
  def handle_event(_event, _params, socket), do: socket

  @doc """
  The rows the section lists for `type`: every stored time, past ones
  included, each with its `t:Tymeslot.MeetingTypes.OfferedTimes.status/0`.
  """
  @spec rows(map() | nil) :: [map()]
  def rows(%{id: id} = type) when is_integer(id) do
    type
    |> OfferedTimes.list_with_status()
    |> Enum.map(fn {offered_time, status} ->
      %{
        id: offered_time.id,
        starts_at: offered_time.starts_at,
        status: status,
        past?: status == :past
      }
    end)
  end

  def rows(_type), do: []

  @doc """
  Whether the form's one-to-one type holds upcoming offered times, with
  fixed dates on or off: group bookings cannot be turned on until they are
  removed (`Tymeslot.MeetingTypes.FixedDates.check_offered_times_kept/2`).
  """
  @spec times_offered?(map()) :: boolean()
  def times_offered?(assigns) do
    Map.get(assigns, :group_bookings_enabled) != true and
      Enum.any?(Map.get(assigns, :offered_time_rows) || [], &(not &1.past?))
  end

  # The type is re-read first: the toggle that turned fixed dates on was
  # saved by autosave, not by this form's copy of it.
  defp add(socket) do
    %{current_user: %{id: user_id}, type: type, host_timezone: timezone} = socket.assigns

    with %{} = type <- type && MeetingTypes.get_meeting_type(type.id, user_id),
         {:ok, starts_at} <-
           SessionHandlers.parse_start(socket.assigns.new_offered_time, timezone),
         {:ok, _offered_time} <- OfferedTimes.add(type, user_id, starts_at) do
      socket
      |> Component.assign(new_offered_time: %{}, offered_time_error: nil)
      |> assign_offered_times()
    else
      {:error, reason} -> Component.assign(socket, :offered_time_error, error_message(reason))
      _no_type -> Component.assign(socket, :offered_time_error, error_message(:not_found))
    end
  end

  defp remove(id, socket) do
    user_id = socket.assigns.current_user.id
    type_id = socket.assigns.type && socket.assigns.type.id

    with %{} = type <- type_id && MeetingTypes.get_meeting_type(type_id, user_id) do
      OfferedTimes.delete(type, user_id, id)
    end

    assign_offered_times(socket)
  end

  defp error_message(:invalid_start),
    do: dgettext("dashboard_meeting_fixed_dates", "Enter the date and time to offer.")

  defp error_message(:start_in_past),
    do: dgettext("dashboard_meeting_fixed_dates", "The time has to lie in the future.")

  defp error_message(:duplicate),
    do: dgettext("dashboard_meeting_fixed_dates", "You already offer that time.")

  defp error_message(:too_many) do
    max = OfferedTimes.max_per_type()

    dngettext(
      "dashboard_meeting_fixed_dates",
      "A meeting type can offer at most %{count} time.",
      "A meeting type can offer at most %{count} times.",
      max,
      count: max
    )
  end

  defp error_message(:not_fixed_dates),
    do:
      dgettext(
        "dashboard_meeting_fixed_dates",
        "Turn on fixed dates, without group bookings, to offer times."
      )

  defp error_message(_reason),
    do:
      dgettext("dashboard_meeting_fixed_dates", "The time could not be added. Please try again.")
end
