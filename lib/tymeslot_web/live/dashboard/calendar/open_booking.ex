defmodule TymeslotWeb.Dashboard.Calendar.OpenBooking do
  @moduledoc """
  Quick create's "Open for booking" kind. The hook sends
  `calendar:open_booking` with its draft id, the meeting type, the
  wall-clock start and end in the organiser's zone, and whether it repeats
  (`open/2`). Nothing in it is trusted.

  "Just this once" widens that day's hours with a date override, and "Every
  week" widens the weekday's weekly hours (`Tymeslot.Availability.Opening`).
  Either way the hours become the smallest window covering the old hours and
  the slot, so the toast names the hours that result rather than the slot.
  The write is local and quick, so it runs in the event and the reply says
  how it went, naming the field at fault on a refusal as a create's does.

  Undo puts the old hours back (`undo/2`). A draft id sent again after its
  opening landed (a reply the hook lost) is accepted without a second write,
  as `Creation` does for creates. Neither redraws the bookable layer itself:
  every availability write broadcasts `{:availability_changed, user_id}`,
  and the surface reloads the layer on it.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias Tymeslot.Availability.Opening
  alias Tymeslot.CalendarGrid.EditGuard
  alias Tymeslot.CalendarGrid.Moves
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Utils.DateTimeUtils.TimeFormat
  alias TymeslotWeb.Dashboard.Calendar.Creation
  alias TymeslotWeb.Dashboard.Calendar.Toast
  alias TymeslotWeb.Dashboard.Calendar.UndoStack
  alias TymeslotWeb.Dashboard.CalendarEditMessages
  alias TymeslotWeb.Helpers.LocaleFormat

  @type socket :: Phoenix.LiveView.Socket.t()
  @type reply ::
          %{accepted: true} | %{accepted: false, field: String.t() | nil, error: String.t()}

  @repeats %{"once" => :once, "weekly" => :weekly}

  @doc "Opens the slot the hook sent, or answers why not. Returns the reply and the socket."
  @spec open(socket(), map()) :: {reply(), socket()}
  def open(socket, %{"draft" => draft} = params) when is_binary(draft) do
    cond do
      not Creation.draft_id?(draft) -> {refused(:invalid), socket}
      Creation.taken?(socket, draft) -> {%{accepted: true}, socket}
      true -> run(socket, draft, params)
    end
  end

  def open(socket, _params), do: {refused(:invalid), socket}

  @doc """
  Undoes an opening: the hours it widened are put back as they were, but
  only while they still hold what the opening wrote. When they have changed
  since (on the Availability page, say), nothing is written and the toast
  says so and where to change them; any other failure says where too, and
  unless the hours are gone the opening goes back on the undo stack so
  Ctrl Z can try again.
  """
  @spec undo(socket(), map()) :: socket()
  def undo(socket, %{kind: :opening, result: result, name: name} = entry) do
    case Opening.restore(socket.assigns.current_user.id, result) do
      :ok ->
        Toast.show(
          socket,
          dgettext("dashboard_calendar_booking", "Bookable times for %{name} put back.",
            name: name
          )
        )

      {:error, :changed} ->
        Toast.show(
          socket,
          dgettext(
            "dashboard_calendar_booking",
            "Couldn't put the bookable times back. They have changed since. Change them on the Availability page."
          )
        )

      {:error, :not_found} ->
        Toast.show(socket, could_not_put_back())

      # Anything else may pass on a second try, so Ctrl Z can make one.
      {:error, _reason} ->
        socket
        |> assign(:undo, UndoStack.push(socket.assigns.undo, entry))
        |> Toast.show(could_not_put_back())
    end
  end

  defp could_not_put_back,
    do:
      dgettext(
        "dashboard_calendar_booking",
        "Couldn't put the bookable times back. Change them on the Availability page."
      )

  defp run(socket, draft, params) do
    user_id = socket.assigns.current_user.id

    timezone = socket.assigns.timezone

    with {:ok, request} <- cast(params, timezone),
         :ok <- EditGuard.rate_limit(user_id),
         {:ok, result} <- write(user_id, request, timezone) do
      {%{accepted: true}, opened(socket, draft, request.meeting_type_id, result)}
    else
      {:error, :rate_limited, _message} = refusal ->
        {_level, message} = CalendarEditMessages.refusal(refusal)
        {%{accepted: false, field: nil, error: message}, socket}

      {:error, reason} ->
        {refused(reason), socket}
    end
  end

  defp cast(params, timezone) do
    with {:ok, meeting_type_id} <- meeting_type(params["meeting_type"]),
         {:ok, repeat} <- repeat(params["repeat"]),
         {:ok, start_at} <- instant(params["start"], timezone),
         {:ok, end_at} <- instant(params["end"], timezone),
         :ok <- ordered(start_at, end_at) do
      {:ok,
       %{meeting_type_id: meeting_type_id, repeat: repeat, start_at: start_at, end_at: end_at}}
    end
  end

  defp meeting_type(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp meeting_type(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} when int > 0 -> {:ok, int}
      _not_an_id -> {:error, :invalid_meeting_type}
    end
  end

  defp meeting_type(_id), do: {:error, :invalid_meeting_type}

  defp repeat(value) do
    case Map.fetch(@repeats, value) do
      {:ok, repeat} -> {:ok, repeat}
      :error -> {:error, :invalid}
    end
  end

  # Whole minutes, as a create's instants are, in the years a create may use.
  defp instant(wall, timezone) do
    case Moves.wall_to_utc(wall, timezone) do
      {:ok, at} ->
        if at.year in Moves.years(),
          do: {:ok, DateTime.truncate(at, :second)},
          else: {:error, :invalid_time}

      :error ->
        {:error, :invalid_time}
    end
  end

  defp ordered(start_at, end_at) do
    if DateTime.compare(end_at, start_at) == :gt, do: :ok, else: {:error, :before_start}
  end

  # The slot is read on the zone the surface showed it in, so the hours
  # written are the ones the toast names.
  defp write(user_id, %{repeat: :once} = request, timezone),
    do:
      Opening.open_once(user_id, request.meeting_type_id, request.start_at, request.end_at,
        timezone: timezone
      )

  defp write(user_id, %{repeat: :weekly} = request, timezone),
    do:
      Opening.open_weekly(user_id, request.meeting_type_id, request.start_at, request.end_at,
        timezone: timezone
      )

  defp opened(socket, draft, meeting_type_id, result) do
    name = meeting_type_name(socket.assigns.current_user.id, meeting_type_id)
    entry = %{kind: :opening, key: {:opening, draft}, id: nil, result: result, name: name}

    socket
    |> Creation.remember_draft(draft)
    |> assign(:undo, UndoStack.push(socket.assigns.undo, entry))
    |> push_event("calendar:create-settled", %{draft: draft})
    |> Toast.show(opened_text(socket, name, result), undo: true, key: entry.key)
  end

  defp meeting_type_name(user_id, id) do
    case MeetingTypes.get_meeting_type(id, user_id) do
      %{name: name} -> name
      nil -> ""
    end
  end

  defp opened_text(socket, name, %{kind: :once, date: date} = result),
    do:
      dgettext(
        "dashboard_calendar_booking",
        "Open for %{name} on %{date}, %{start} to %{finish}",
        name: name,
        date: LocaleFormat.format_short_weekday_date(date, locale()),
        start: clock(socket, result.start_time),
        finish: finish(socket, result)
      )

  defp opened_text(socket, name, %{kind: :weekly, day_of_week: day} = result) do
    weekly =
      dgettext(
        "dashboard_calendar_booking",
        "Open for %{name} every %{weekday}, %{start} to %{finish}",
        name: name,
        weekday: LocaleFormat.format_weekday_name(day, locale(), :full),
        start: clock(socket, result.start_time),
        finish: finish(socket, result)
      )

    and_on_date(socket, weekly, result.previous.override)
  end

  # The slot's date had hours of its own, so they were widened too.
  defp and_on_date(_socket, text, nil), do: text

  defp and_on_date(socket, text, %{date: date, hours: hours}),
    do:
      dgettext(
        "dashboard_calendar_booking",
        "%{opened}, and on %{date}, %{start} to %{finish}",
        opened: text,
        date: LocaleFormat.format_short_weekday_date(date, locale()),
        start: clock(socket, hours.start_time),
        finish: finish(socket, hours)
      )

  defp finish(socket, %{end_time: time, ends_next_day: true}),
    do: dgettext("dashboard_calendar_booking", "%{time} the next day", time: clock(socket, time))

  defp finish(socket, %{end_time: time}), do: clock(socket, time)

  defp clock(socket, time), do: TimeFormat.format(time, socket.assigns.time_format)

  defp locale, do: Gettext.get_locale(TymeslotWeb.Gettext)

  defp refused(reason) do
    {field, message} = refusal(reason)
    %{accepted: false, field: field, error: message}
  end

  defp refusal(reason) when reason in [:not_found, :invalid_meeting_type],
    do:
      {"meeting_type",
       dgettext(
         "dashboard_calendar_booking",
         "That meeting type can't be opened. Choose another one."
       )}

  defp refusal(:in_past),
    do:
      {"start",
       dgettext("dashboard_calendar_booking", "That time has passed. Choose a later one.")}

  defp refusal(:invalid_time),
    do: {"start", dgettext("dashboard_calendar_booking", "That date or time can't be read.")}

  defp refusal(reason) when reason in [:before_start, :invalid_range],
    do: {"end", dgettext("dashboard_calendar_booking", "The time must end after it starts.")}

  defp refusal(:widened_too_long),
    do:
      {nil,
       dgettext(
         "dashboard_calendar_booking",
         "That would make the day's hours longer than 24 hours. Change them on the Availability page."
       )}

  defp refusal(:too_long),
    do: {"end", dgettext("dashboard_calendar_booking", "Open at most 24 hours at a time.")}

  defp refusal(:breaks_outside_hours),
    do:
      {nil,
       dgettext(
         "dashboard_calendar_booking",
         "A break that day would fall outside its hours. Change it on the Availability page."
       )}

  defp refusal(:invalid_hours),
    do:
      {nil,
       dgettext(
         "dashboard_calendar_booking",
         "Those hours can't be saved. Check that day on the Availability page."
       )}

  defp refusal(_other),
    do:
      {nil, dgettext("dashboard_calendar_booking", "Couldn't open that time. Please try again.")}
end
