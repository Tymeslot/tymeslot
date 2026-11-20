defmodule TymeslotWeb.Dashboard.Calendar.PanelGroupEvent do
  @moduledoc """
  "Group event" in the side panel's New event state: the draft
  becomes a one-off event people sign up for
  (`Tymeslot.MeetingTypes.OneOffEvents`), a fixed-date group meeting type
  with its one session, instead of a bare calendar event.

  The event's own fields live in the panel's `form` beside the draft's
  (`"group_event"`, `"max_participants"`, `"group_location"`, `"closes_at"`),
  so the form draws what was typed; the draft's title, times and calendar
  are the event's, and its notes are the event's description. A group event
  has times and no guests of its own: people sign up through its booking
  link. It is offered only to an organiser whose plan includes group
  bookings, on a draft without guests, typed or added (`offered?/2`).

  Create checks the fields in the organiser's time zone and creates the
  event at once. On success the panel closes, the calendar reloads with the
  session on it, and the organiser is shown the event's booking link to
  share. A refusal stays in the panel's header, with what was typed, to
  correct and create again.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Ecto.Changeset
  alias Tymeslot.CalendarGrid.MeetingParams
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.InputValidation
  alias Tymeslot.MeetingTypes.OneOffEvents
  alias Tymeslot.Utils.ChangesetErrors
  alias Tymeslot.Utils.UrlBuilder
  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.Components.CoreComponents.DateTimePicker.Value
  alias TymeslotWeb.Dashboard.Calendar.Creation
  alias TymeslotWeb.Dashboard.Calendar.PanelMeeting
  alias TymeslotWeb.Dashboard.Calendar.PanelNew
  alias TymeslotWeb.Dashboard.Calendar.PanelState
  alias TymeslotWeb.Dashboard.Calendar.SurfaceData

  @type socket :: Phoenix.LiveView.Socket.t()

  @fields ~w(group_event max_participants group_location closes_at)

  @doc "The group-event fields a new draft starts with."
  @spec defaults() :: map()
  def defaults,
    do: %{
      "group_event" => false,
      "max_participants" => "10",
      "group_location" => "",
      "closes_at" => ""
    }

  @doc """
  The group-event fields among a form change's `params`, cleaned; with the
  box ticked, all day is off.
  """
  @spec fields(map()) :: map()
  def fields(params) do
    params
    |> Map.take(@fields)
    |> Map.new(&field/1)
    |> timed()
  end

  defp field({"group_event", value}), do: {"group_event", value in [true, "true", "on"]}
  defp field({key, value}) when is_binary(value), do: {key, String.replace(value, "\x00", "")}
  defp field({key, _value}), do: {key, ""}

  defp timed(%{"group_event" => true} = fields), do: Map.put(fields, "all_day", false)
  defp timed(fields), do: fields

  @doc """
  Whether the box is offered: the organiser's plan includes group bookings
  (`allowed`) and the draft has no guests, who would have nowhere to go. An
  address typed into the guest field and not added yet counts
  (`PanelMeeting.guests?/1`), as Create would invite it: ticking the box
  would hide the field and drop the address unsent.
  """
  @spec offered?(boolean(), map()) :: boolean()
  def offered?(allowed, form), do: allowed == true and not PanelMeeting.guests?(form)

  @doc "Whether the form describes a group event: the box ticked, on a draft offered it."
  @spec on?(boolean(), map()) :: boolean()
  def on?(allowed, form), do: form["group_event"] == true and offered?(allowed, form)

  @doc """
  Creates the panel's group event: checks it, spends the budget the panel's
  meetings share, and creates it. A refusal stays in the panel's header.
  """
  @spec create(socket(), map()) :: socket()
  def create(socket, panel) do
    case build_params(socket, panel.form) do
      {:ok, params} -> created(socket, OneOffEvents.create(params))
      {:error, message} -> refuse(socket, panel, message)
    end
  end

  defp created(socket, {:ok, %{meeting_type: meeting_type}}) do
    send(self(), {:flash, {:info, created_message(socket, meeting_type)}})

    socket
    |> PanelState.close()
    |> SurfaceData.reload(:events)
  end

  defp created(socket, {:error, reason}),
    do: refuse(socket, socket.assigns.panel, error_message(reason))

  defp build_params(socket, form) do
    user_id = socket.assigns.current_user.id
    timezone = socket.assigns.timezone

    with {:ok, name} <- title(form["title"]),
         {:ok, create} <- cast(socket, form),
         {:ok, duration} <- duration(create),
         {:ok, max_participants} <- participant_limit(form["max_participants"]),
         {:ok, location} <- location(form["group_location"]),
         {:ok, description} <- description(form["description"]),
         {:ok, closes_at} <- registration_close(form["closes_at"], timezone),
         :ok <- rate_limit(user_id) do
      {:ok,
       %{
         user_id: user_id,
         name: name,
         description: description,
         starts_at: create.start_at,
         duration_minutes: duration,
         max_participants: max_participants,
         location: location,
         registration_closes_at: closes_at,
         calendar_integration_id: create.integration_id,
         target_calendar_id: create.calendar_id
       }}
    end
  end

  # The draft's times and calendar, read as every create reads them.
  defp cast(socket, form) do
    # A group event is booked through its calendar, so it needs one.
    case PanelNew.cast_form(
           socket,
           Map.merge(form, %{"all_day" => false, "guests" => []}),
           :required
         ) do
      {:ok, create} -> {:ok, create}
      {:error, field, reason} -> {:error, Creation.refusal_message(field, reason)}
    end
  end

  # The title becomes the event's meeting type name, so it is checked and
  # sanitised by the same rule as a name typed into the meeting-type form.
  defp title(title) when is_binary(title) do
    case String.trim(title) do
      "" -> {:error, dgettext("dashboard_group_events", "Give the event a title.")}
      trimmed -> validated(:name, trimmed)
    end
  end

  defp title(_title), do: title("")

  defp description(value) do
    case validated(:description, value || "") do
      {:ok, ""} -> {:ok, nil}
      result -> result
    end
  end

  defp validated(name, value) do
    case InputValidation.validate_field(name, value, %{}) do
      {:ok, sanitised} -> {:ok, sanitised}
      {:error, errors} -> {:error, errors |> Map.values() |> List.first()}
    end
  end

  # One day at most, as any meeting type: an event is one session, not a span.
  defp duration(%{start_at: starts_at, end_at: ends_at}) do
    duration = div(DateTime.diff(ends_at, starts_at), 60)
    step = Constraints.duration_step_minutes()

    cond do
      duration not in Constraints.duration_minutes_range() ->
        {:error,
         dgettext(
           "dashboard_group_events",
           "An event lasts at least 5 minutes and at most 24 hours."
         )}

      rem(duration, step) != 0 ->
        {:error,
         dgettext("dashboard_group_events", "An event lasts a multiple of %{step} minutes.",
           step: step
         )}

      true ->
        {:ok, duration}
    end
  end

  defp participant_limit(value) do
    range = Constraints.group_participants_range()

    case integer(value) do
      limit when is_integer(limit) and limit >= range.first and limit <= range.last ->
        {:ok, limit}

      _outside ->
        {:error,
         dgettext("dashboard_group_events", "Allow between %{min} and %{max} participants.",
           min: range.first,
           max: range.last
         )}
    end
  end

  defp location("venue:" <> id), do: location_id(:venue, id)
  defp location("video:" <> id), do: location_id(:video, id)

  defp location(_none),
    do: {:error, dgettext("dashboard_group_events", "Choose where the event takes place.")}

  defp location_id(kind, id) do
    case integer(id) do
      id when is_integer(id) -> {:ok, {kind, id}}
      _invalid -> location(nil)
    end
  end

  defp integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> number
      _not_a_number -> nil
    end
  end

  defp integer(_value), do: nil

  # The picker posts the half it has of a date and time left unfinished, which
  # is refused with what is missing rather than read as no close.
  defp registration_close(value, timezone) do
    case Value.parse(value) do
      {:ok, nil} -> {:ok, nil}
      {:ok, naive} -> close_in_zone(naive, timezone)
      {:error, :invalid} -> {:error, error_message(:invalid_registration_close)}
      {:error, unfinished} -> {:error, Value.message(unfinished)}
    end
  end

  defp close_in_zone(naive, timezone) do
    case in_zone(naive, timezone) do
      {:ok, closes_at} -> {:ok, DateTime.truncate(closes_at, :second)}
      {:error, _reason} -> {:error, error_message(:invalid_registration_close)}
    end
  end

  # A wall time the clock skips counts from just after the gap; one it
  # passes twice, from the first time.
  defp in_zone(naive, timezone) do
    case DateTime.from_naive(naive, timezone) do
      {:ok, at} -> {:ok, DateTime.shift_zone!(at, "Etc/UTC")}
      {:ambiguous, first, _second} -> {:ok, DateTime.shift_zone!(first, "Etc/UTC")}
      {:gap, _before, after_gap} -> {:ok, DateTime.shift_zone!(after_gap, "Etc/UTC")}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rate_limit(user_id) do
    case MeetingParams.rate_limit(user_id) do
      :ok ->
        :ok

      {:error, :rate_limited, _message} ->
        {:error,
         dgettext("dashboard_calendar_events", "Too many new meetings. Please wait a moment.")}
    end
  end

  defp created_message(socket, meeting_type) do
    username = socket.assigns[:profile] && socket.assigns.profile.username
    link = UrlBuilder.booking_url(username) <> "/" <> MeetingTypes.effective_slug(meeting_type)

    dgettext("dashboard_group_events", "Event created. Its booking link: %{link}", link: link)
  end

  defp error_message(:start_in_past),
    do: dgettext("dashboard_group_events", "The event has to start in the future.")

  defp error_message(:invalid_registration_close),
    do:
      dgettext(
        "dashboard_group_events",
        "Registration has to close in the future, and no later than the event starts."
      )

  # The clash may be with a booking the host cannot see (one awaiting its
  # attendee's email verification or payment), so it never claims one is there.
  defp error_message(:time_conflict),
    do:
      dgettext(
        "dashboard_group_events",
        "This time is no longer available. Please choose another time."
      )

  defp error_message(:no_calendar),
    do:
      dgettext(
        "dashboard_group_events",
        "Connect a calendar first: people book the event on your booking page, which needs one."
      )

  defp error_message(:group_bookings_not_allowed),
    do: dgettext("dashboard_group_events", "Group events are not included in your plan.")

  # A rule the checks above do not restate (a link or name taken in the
  # meantime): the changeset says which.
  defp error_message(%Changeset{} = changeset),
    do: ChangesetErrors.first(changeset, &ChangesetErrors.translate/1) || error_message(nil)

  defp error_message(_reason),
    do: dgettext("dashboard_group_events", "The event could not be created. Please try again.")

  defp refuse(socket, panel, message),
    do: assign(socket, :panel, %{panel | status: {:failed, message}})
end
