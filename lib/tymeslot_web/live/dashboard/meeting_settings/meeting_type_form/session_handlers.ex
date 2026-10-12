defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.SessionHandlers do
  @moduledoc """
  Event handling for the meeting-type form's fixed dates
  (`MeetingTypeForm.FixedDatesSection`): the toggle, planning a date and
  cancelling one.

  The dates are the type's planned sessions (`Tymeslot.Meetings.PlannedSessions`),
  read fresh after every change rather than kept in the form's own state:
  each one is a meeting, with people booked on it, not a form field.
  Times are entered and shown in the host's own time zone.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.Component
  alias Tymeslot.Clock
  alias Tymeslot.Meetings.{PlannedSessions, Seats}
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.FixedDates
  alias Tymeslot.Profiles
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.Autosave

  @doc "Assigns the type's planned dates, the host's time zone and the input row's state."
  @spec assign_sessions(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_sessions(socket) do
    timezone =
      case socket.assigns[:current_user] do
        %{id: user_id} -> Profiles.get_user_timezone(user_id)
        _no_user -> "Etc/UTC"
      end

    socket
    |> Component.assign(:host_timezone, timezone)
    |> Component.assign(:session_rows, rows(socket.assigns[:type]))
    |> Component.assign_new(:new_session, fn -> %{} end)
    |> Component.assign_new(:session_error, fn -> nil end)
    |> Component.assign_new(:confirming_session_id, fn -> nil end)
  end

  @doc "The rows the section lists for `type`: every live planned date, past ones included."
  @spec rows(map() | nil) :: [map()]
  def rows(%{id: id} = type) when is_integer(id) do
    now = Clock.utc_now()

    type
    |> PlannedSessions.list()
    |> Enum.map(fn session ->
      %{
        id: session.id,
        start_time: session.start_time,
        registration_closes_at: session.registration_closes_at,
        capacity: session.capacity,
        seats_taken: Seats.seats_taken(session.id),
        participants: PlannedSessions.participant_count(session),
        past?: DateTime.compare(session.start_time, now) != :gt
      }
    end)
  end

  def rows(_type), do: []

  @spec toggle_fixed_dates(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def toggle_fixed_dates(socket) do
    upcoming? = Enum.any?(socket.assigns[:session_rows] || [], &(not &1.past?))

    if socket.assigns.fixed_dates and upcoming? do
      socket
    else
      socket
      |> Component.assign(:fixed_dates, not socket.assigns.fixed_dates)
      |> Autosave.maybe_run()
    end
  end

  @spec update_input(map(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def update_input(%{"session" => params}, socket) when is_map(params) do
    Component.assign(socket,
      new_session:
        Map.merge(socket.assigns[:new_session] || %{}, Map.take(params, ~w(date time closes_at))),
      session_error: nil
    )
  end

  def update_input(_params, socket), do: socket

  @doc """
  Plans the date in the input row. The type is re-read first: the toggle
  that made it a fixed-date type was saved by autosave, not by this form's
  copy of it.
  """
  @spec add(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def add(socket) do
    %{current_user: %{id: user_id}, type: type, host_timezone: timezone} = socket.assigns
    input = socket.assigns[:new_session] || %{}

    with %{} = type <- type && MeetingTypes.get_meeting_type(type.id, user_id),
         true <- FixedDates.enabled?(type) || {:error, :not_fixed_dates},
         {:ok, starts_at} <- parse_start(input, timezone),
         {:ok, closes_at} <- parse_close(input["closes_at"], timezone),
         {:ok, _session} <-
           PlannedSessions.add(type, starts_at, registration_closes_at: closes_at) do
      socket
      |> Component.assign(new_session: %{}, session_error: nil)
      |> assign_sessions()
    else
      {:error, reason} -> Component.assign(socket, :session_error, error_message(reason))
      _no_type -> Component.assign(socket, :session_error, error_message(:not_fixed_dates))
    end
  end

  @spec ask_to_cancel(String.t(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def ask_to_cancel(id, socket) do
    case Enum.find(socket.assigns[:session_rows] || [], &(&1.id == id)) do
      %{participants: 0} -> cancel(id, socket)
      %{} -> Component.assign(socket, :confirming_session_id, id)
      nil -> socket
    end
  end

  @spec keep(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def keep(socket), do: Component.assign(socket, :confirming_session_id, nil)

  @doc "Cancels a planned date of this type, telling everyone booked on it."
  @spec cancel(String.t(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def cancel(id, socket) do
    user_id = socket.assigns.current_user.id
    type_id = socket.assigns.type && socket.assigns.type.id

    with %{} = type <- type_id && MeetingTypes.get_meeting_type(type_id, user_id),
         %{} = session <- Enum.find(PlannedSessions.list(type), &(&1.id == id)) do
      PlannedSessions.cancel(session, user_id)
    end

    socket
    |> Component.assign(:confirming_session_id, nil)
    |> assign_sessions()
  end

  defp parse_start(%{"date" => date, "time" => time}, timezone)
       when is_binary(date) and is_binary(time) do
    with {:ok, date} <- Date.from_iso8601(date),
         {:ok, time} <- Time.from_iso8601(pad_seconds(time)),
         {:ok, local} <- DateTime.new(date, time, timezone) do
      {:ok, DateTime.shift_zone!(local, "Etc/UTC")}
    else
      _invalid -> {:error, :invalid_start}
    end
  end

  defp parse_start(_input, _timezone), do: {:error, :invalid_start}

  defp parse_close(value, _timezone) when value in [nil, ""], do: {:ok, nil}

  defp parse_close(value, timezone) when is_binary(value) do
    with [date, time] <- String.split(value, "T", parts: 2),
         {:ok, date} <- Date.from_iso8601(date),
         {:ok, time} <- Time.from_iso8601(pad_seconds(time)),
         {:ok, local} <- DateTime.new(date, time, timezone) do
      {:ok, DateTime.shift_zone!(local, "Etc/UTC")}
    else
      _invalid -> {:error, :invalid_registration_close}
    end
  end

  # A time input posts "18:00"; a browser set to show seconds posts
  # "18:00:00".
  defp pad_seconds(time) do
    if String.length(time) == 5, do: time <> ":00", else: time
  end

  defp error_message(:invalid_start),
    do: dgettext("dashboard_meeting_form", "Enter the date and time of the session.")

  defp error_message(:start_in_past),
    do: dgettext("dashboard_meeting_form", "The date has to lie in the future.")

  defp error_message(:invalid_registration_close),
    do:
      dgettext(
        "dashboard_meeting_form",
        "Registration has to close in the future, and no later than the session starts."
      )

  defp error_message(:time_conflict),
    do: dgettext("dashboard_meeting_form", "You already have a booking at that time.")

  defp error_message(:not_fixed_dates),
    do: dgettext("dashboard_meeting_form", "Turn on fixed dates and group bookings first.")

  defp error_message(_reason),
    do: dgettext("dashboard_meeting_form", "The date could not be planned. Please try again.")
end
