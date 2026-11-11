defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.SessionHandlers do
  @moduledoc """
  Event handling for the meeting-type form's fixed dates
  (`MeetingTypeForm.FixedDatesSection`): the toggle, planning a date,
  editing one (moving it, or when its registration closes), and cancelling
  one. A one-to-one type's offered times are handed on to
  `OfferedTimeHandlers`.

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
  alias Tymeslot.Utils.DateTimeUtils
  alias TymeslotWeb.Components.CoreComponents.DateTimePicker.Value
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.{Autosave, OfferedTimeHandlers}
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

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
    |> Component.assign_new(:session_notice, fn -> nil end)
    |> Component.assign_new(:confirming_session_id, fn -> nil end)
    |> Component.assign_new(:editing_session, fn -> nil end)
  end

  @doc """
  The form's events for the fixed dates, by name; `MeetingTypeForm` hands
  each of them here.
  """
  @spec events() :: [String.t()]
  def events,
    do: ~w(toggle_fixed_dates update_session_input add_session remove_session cancel_session
           keep_session edit_session update_session_edit save_session_edit
           discard_session_edit) ++ OfferedTimeHandlers.events()

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          Phoenix.LiveView.Socket.t()
  def handle_event("toggle_fixed_dates", _params, socket), do: toggle_fixed_dates(socket)

  def handle_event("update_session_input", params, socket), do: update_input(params, socket)
  def handle_event("add_session", _params, socket), do: add(socket)
  def handle_event("remove_session", %{"id" => id}, socket), do: ask_to_cancel(id, socket)
  def handle_event("cancel_session", %{"id" => id}, socket), do: cancel(id, socket)
  def handle_event("keep_session", _params, socket), do: keep(socket)
  def handle_event("edit_session", %{"id" => id}, socket), do: edit(id, socket)

  def handle_event("update_session_edit", %{"session_edit" => params}, socket)
      when is_map(params) and is_map(socket.assigns.editing_session) do
    editing = socket.assigns.editing_session
    input = Map.merge(editing.input, Map.take(params, ~w(date time closes_at)))
    Component.assign(socket, :editing_session, %{editing | input: input, error: nil})
  end

  def handle_event("save_session_edit", _params, socket), do: save_edit(socket)

  def handle_event("discard_session_edit", _params, socket),
    do: Component.assign(socket, :editing_session, nil)

  # Any other event of `events/0` is an offered time's.
  def handle_event(event, params, socket),
    do: OfferedTimeHandlers.handle_event(event, params, socket)

  @doc "The rows the section lists for `type`: every live planned date, past ones included."
  @spec rows(map() | nil) :: [map()]
  def rows(%{id: id} = type) when is_integer(id) do
    now = Clock.utc_now()
    sessions = PlannedSessions.list(type)
    counts = sessions |> Enum.map(& &1.id) |> Seats.counts_by_meeting()

    Enum.map(sessions, fn session ->
      %{participants: participants, seats_taken: seats_taken} = counts[session.id]

      %{
        id: session.id,
        start_time: session.start_time,
        registration_closes_at: session.registration_closes_at,
        capacity: session.capacity,
        seats_taken: seats_taken,
        participants: participants,
        past?: DateTime.compare(session.start_time, now) != :gt,
        open?: PlannedSessions.open?(session, now)
      }
    end)
  end

  def rows(_type), do: []

  @doc """
  Whether the form's fixed dates are held on by upcoming planned dates:
  neither fixed dates nor group bookings can be turned off until those are
  cancelled (`Tymeslot.MeetingTypes.FixedDates.check_sessions_kept/2`).
  """
  @spec dates_planned?(map()) :: boolean()
  def dates_planned?(assigns) do
    Map.get(assigns, :fixed_dates) == true and
      Enum.any?(Map.get(assigns, :session_rows) || [], &(not &1.past?))
  end

  @spec toggle_fixed_dates(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def toggle_fixed_dates(socket) do
    if dates_planned?(socket.assigns) do
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
      session_error: nil,
      session_notice: nil
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
         true <- FixedDates.sessions?(type) || {:error, :not_fixed_dates},
         {:ok, starts_at} <- parse_start(input, timezone),
         {:ok, closes_at} <- parse_close(input["closes_at"], timezone),
         {:ok, _session} <-
           PlannedSessions.add(type, user_id, starts_at, registration_closes_at: closes_at) do
      socket
      |> Component.assign(
        new_session: %{},
        session_error: nil,
        session_notice: clock_change_notice(input, timezone)
      )
      |> assign_sessions()
    else
      {:error, reason} ->
        Component.assign(socket, session_error: error_message(reason), session_notice: nil)

      _no_type ->
        Component.assign(socket,
          session_error: error_message(:not_fixed_dates),
          session_notice: nil
        )
    end
  end

  @doc """
  Cancels a date nobody is booked on at once, and asks first otherwise. The
  count is read at the click, not from the rows on screen, so a date someone
  booked a moment ago asks too; the rows are refreshed with it, so the
  question names everyone booked.
  """
  @spec ask_to_cancel(String.t(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def ask_to_cancel(id, socket) do
    case owned_session(socket, id) do
      nil ->
        socket

      session ->
        if PlannedSessions.participant_count(session) == 0,
          do: cancel(id, socket),
          else: socket |> Component.assign(:confirming_session_id, id) |> assign_sessions()
    end
  end

  @spec keep(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def keep(socket), do: Component.assign(socket, :confirming_session_id, nil)

  @doc "Cancels a planned date of this type, telling everyone booked on it."
  @spec cancel(String.t(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def cancel(id, socket) do
    with %{} = session <- owned_session(socket, id) do
      PlannedSessions.cancel(session, socket.assigns.current_user.id)
    end

    socket
    |> Component.assign(:confirming_session_id, nil)
    |> assign_sessions()
  end

  # The planned date `id` of the form's type, re-read and scoped to the host,
  # or nil for an id that is not one of theirs.
  defp owned_session(socket, id) do
    user_id = socket.assigns.current_user.id
    type_id = socket.assigns.type && socket.assigns.type.id

    with %{} = type <- type_id && MeetingTypes.get_meeting_type(type_id, user_id) do
      Enum.find(PlannedSessions.list(type), &(&1.id == id))
    end
  end

  # Opens a row for editing, prefilled with its date, time and registration
  # close in the host's time zone (an empty close: at the start).
  defp edit(id, socket) do
    timezone = socket.assigns.host_timezone

    case Enum.find(socket.assigns[:session_rows] || [], &(&1.id == id and not &1.past?)) do
      %{start_time: start_time, registration_closes_at: closes_at} ->
        [date, time] = start_time |> local_input(timezone) |> String.split("T")
        closes = if closes_at, do: local_input(closes_at, timezone), else: ""
        input = %{"date" => date, "time" => time, "closes_at" => closes}
        Component.assign(socket, :editing_session, %{id: id, input: input, error: nil})

      nil ->
        socket
    end
  end

  # A new date or time moves the session, with everyone on it; otherwise
  # only its registration close changes.
  defp save_edit(%{assigns: %{editing_session: %{id: id, input: input} = editing}} = socket) do
    %{current_user: %{id: user_id}, host_timezone: timezone} = socket.assigns

    with {:ok, starts_at} <- parse_start(input, timezone),
         {:ok, closes_at} <- parse_close(input["closes_at"], timezone),
         %{} = session <- owned_session(socket, id),
         {:ok, _session} <- apply_edit(session, user_id, starts_at, closes_at) do
      socket
      |> Component.assign(
        editing_session: nil,
        session_notice: clock_change_notice(input, timezone)
      )
      |> assign_sessions()
    else
      {:error, reason} ->
        Component.assign(socket, :editing_session, %{editing | error: error_message(reason)})

      _gone ->
        socket |> Component.assign(:editing_session, nil) |> assign_sessions()
    end
  end

  defp save_edit(socket), do: socket

  defp apply_edit(session, user_id, starts_at, closes_at) do
    if DateTime.compare(starts_at, session.start_time) == :eq,
      do: PlannedSessions.set_registration_close(session, user_id, closes_at),
      else: PlannedSessions.move(session, user_id, starts_at, closes_at)
  end

  defp local_input(datetime, timezone),
    do: datetime |> DateTime.shift_zone!(timezone) |> Calendar.strftime("%Y-%m-%dT%H:%M")

  @doc """
  The instant (UTC) a `"date"` and `"time"` the host entered in `timezone`
  name. A local time the clock change skips or repeats resolves as
  everywhere else in the app (`DateTimeUtils.resolve_local/3`): to the end
  of the gap, or to its first occurrence.
  """
  @spec parse_start(map(), String.t()) :: {:ok, DateTime.t()} | {:error, :invalid_start}
  def parse_start(%{"date" => date, "time" => time}, timezone)
      when is_binary(date) and is_binary(time) do
    with {:ok, date} <- Date.from_iso8601(date),
         {:ok, time} <- Time.from_iso8601(pad_seconds(time)),
         {:ok, local} <- DateTimeUtils.resolve_local(date, time, timezone) do
      {:ok, DateTime.shift_zone!(local, "Etc/UTC")}
    else
      _invalid -> {:error, :invalid_start}
    end
  end

  def parse_start(_input, _timezone), do: {:error, :invalid_start}

  @doc """
  What to tell the host when the `"date"` and `"time"` they entered in
  `timezone` is not a plain local time, or nil when it is: a time a
  spring-forward gap skips, which `parse_start/2` saved at the end of the
  gap, or a time a fall-back overlap repeats, which it saved at the first
  occurrence. The rule itself is `DateTimeUtils.resolve_local/3`'s; this only
  reports it.
  """
  @spec clock_change_notice(map(), String.t()) :: String.t() | nil
  def clock_change_notice(%{"date" => date, "time" => time}, timezone)
      when is_binary(date) and is_binary(time) do
    with {:ok, date} <- Date.from_iso8601(date),
         {:ok, time} <- Time.from_iso8601(pad_seconds(time)) do
      date |> DateTime.new(time, timezone) |> notice(date, time)
    else
      _invalid -> nil
    end
  end

  def clock_change_notice(_input, _timezone), do: nil

  defp notice({:gap, _just_before, just_after}, date, time),
    do:
      dgettext(
        "dashboard_meeting_fixed_dates",
        "%{time} does not exist on %{date} because the clocks go forward, so the time was saved as %{saved}.",
        time: LocalizationHelpers.format_time_by_locale(time),
        date: LocalizationHelpers.format_date(date),
        saved: LocalizationHelpers.format_time_by_locale(just_after)
      )

  defp notice({:ambiguous, first, _second}, date, time),
    do:
      dgettext(
        "dashboard_meeting_fixed_dates",
        "%{time} happens twice on %{date} because the clocks go back, so the earlier one (%{zone}) was saved.",
        time: LocalizationHelpers.format_time_by_locale(time),
        date: LocalizationHelpers.format_date(date),
        zone: first.zone_abbr
      )

  defp notice(_plain_or_invalid, _date, _time), do: nil

  defp parse_close(value, _timezone) when value in [nil, ""], do: {:ok, nil}

  defp parse_close(value, timezone) when is_binary(value) do
    if Value.unfinished(value), do: {:error, :unfinished_close}, else: read_close(value, timezone)
  end

  defp read_close(value, timezone) do
    with [date, time] <- String.split(value, "T", parts: 2),
         {:ok, date} <- Date.from_iso8601(date),
         {:ok, time} <- Time.from_iso8601(pad_seconds(time)),
         {:ok, local} <- DateTimeUtils.resolve_local(date, time, timezone) do
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
    do: dgettext("dashboard_meeting_fixed_dates", "Enter the date and time of the session.")

  defp error_message(:start_in_past),
    do: dgettext("dashboard_meeting_fixed_dates", "The date has to lie in the future.")

  # The picker says under itself which half is missing.
  defp error_message(:unfinished_close), do: nil

  defp error_message(:invalid_registration_close),
    do:
      dgettext(
        "dashboard_meeting_fixed_dates",
        "Registration has to close in the future, and no later than the session starts."
      )

  defp error_message(:session_started),
    do: dgettext("dashboard_meeting_fixed_dates", "This date has already started.")

  defp error_message(:time_conflict),
    do: dgettext("dashboard_meeting_fixed_dates", "You already have a booking at that time.")

  defp error_message(:not_fixed_dates),
    do: dgettext("dashboard_meeting_fixed_dates", "Turn on fixed dates and group bookings first.")

  defp error_message(_reason),
    do:
      dgettext(
        "dashboard_meeting_fixed_dates",
        "The date could not be planned. Please try again."
      )
end
