defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.GroupEventCreation do
  @moduledoc """
  Saves Quick Add's group-event mode: a one-off event people sign up for
  (`Tymeslot.MeetingTypes.OneOffEvents`).

  The form's fields are parsed and checked here, in the organiser's time
  zone, before anything is written. On success the dialog closes, the grid
  reloads with the event on it, and the organiser is shown the event's
  booking link to share. Failures stay on the open dialog as a message.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.OneOffEvents
  alias Tymeslot.Utils.UrlBuilder
  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers.DataLoading

  @doc """
  Records the group-event fields as their form posts them. They are parsed
  and checked on save (`save/2`), where the event is created.
  """
  @spec update_fields(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def update_fields(%{"group_event" => params}, socket) when is_map(params) do
    case socket.assigns.creating_event do
      %{group_event: current} = creating ->
        fields =
          Map.merge(
            current,
            Map.take(params, ~w(max_participants location closes_at description))
          )

        {:noreply, assign(socket, :creating_event, %{creating | group_event: fields})}

      _not_creating ->
        {:noreply, socket}
    end
  end

  def update_fields(_params, socket), do: {:noreply, socket}

  @spec save(map(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def save(creating, socket) do
    case build_params(creating, socket) do
      {:ok, params} -> create(params, socket)
      {:error, message} -> fail(socket, message)
    end
  end

  defp build_params(creating, socket) do
    timezone = socket.assigns.user_timezone
    fields = creating[:group_event] || %{}

    with :ok <- authorize_integration(socket, creating[:integration_id]),
         {:ok, title} <- title(creating[:title]),
         {:ok, starts_at, duration} <- timing(creating, timezone),
         {:ok, max_participants} <- participant_limit(fields["max_participants"]),
         {:ok, location} <- location(fields["location"]),
         {:ok, closes_at} <- registration_close(fields["closes_at"], timezone),
         :ok <- rate_limit(socket) do
      {:ok,
       %{
         user_id: socket.assigns.current_user.id,
         name: title,
         description: blank_to_nil(fields["description"]),
         starts_at: starts_at,
         duration_minutes: duration,
         max_participants: max_participants,
         location: location,
         registration_closes_at: closes_at,
         calendar_integration_id: creating[:integration_id],
         target_calendar_id: creating[:integration_id] && creating[:calendar_id]
       }}
    end
  end

  defp create(params, socket) do
    case OneOffEvents.create(params) do
      {:ok, %{meeting_type: meeting_type}} ->
        send(self(), {:flash, {:info, created_message(meeting_type, socket)}})

        {:noreply,
         socket
         |> assign(:creating_event, nil)
         |> assign(:saving_event, false)
         |> DataLoading.load_events()}

      {:error, reason} ->
        fail(socket, error_message(reason))
    end
  end

  defp fail(socket, message) do
    send(self(), {:flash, {:error, message}})
    {:noreply, socket}
  end

  defp created_message(meeting_type, socket) do
    username = socket.assigns[:profile] && socket.assigns.profile.username
    link = UrlBuilder.booking_url(username) <> "/" <> MeetingTypes.effective_slug(meeting_type)

    dgettext("dashboard_group_events", "Event created. Its booking link: %{link}", link: link)
  end

  defp authorize_integration(_socket, nil), do: :ok

  defp authorize_integration(socket, integration_id) do
    case EditWorkflow.assert_owns_integration(socket, integration_id) do
      :ok -> :ok
      _not_owned -> {:error, dgettext("dashboard_calendar_events", "Invalid calendar selected")}
    end
  end

  defp title(title) when is_binary(title) do
    case String.trim(title) do
      "" -> {:error, dgettext("dashboard_group_events", "Give the event a title.")}
      trimmed -> {:ok, trimmed}
    end
  end

  defp title(_title), do: title("")

  # One day at most, as any meeting type: an event is one session, not a span.
  defp timing(creating, timezone) do
    with {:ok, start_date} <- Date.from_iso8601(creating.date),
         {:ok, end_date} <- Date.from_iso8601(creating.end_date),
         {:ok, starts_at} <-
           Shared.to_utc(start_date, creating.start_hour, creating.start_minute, timezone),
         {:ok, ends_at} <-
           Shared.to_utc(end_date, creating.end_hour, creating.end_minute, timezone),
         duration = div(DateTime.diff(ends_at, starts_at), 60),
         true <- duration in Constraints.duration_minutes_range() do
      {:ok, starts_at, duration}
    else
      _invalid ->
        {:error,
         dgettext(
           "dashboard_group_events",
           "An event lasts at least 5 minutes and at most 24 hours."
         )}
    end
  end

  defp participant_limit(value) do
    range = Constraints.group_participants_range()

    case Shared.parse_optional_int(value) do
      limit when is_integer(limit) ->
        if limit in range, do: {:ok, limit}, else: participant_limit_error(range)

      _not_a_number ->
        participant_limit_error(range)
    end
  end

  defp participant_limit_error(range) do
    {:error,
     dgettext("dashboard_group_events", "Allow between %{min} and %{max} participants.",
       min: range.first,
       max: range.last
     )}
  end

  defp location("venue:" <> id), do: location_id(:venue, id)
  defp location("video:" <> id), do: location_id(:video, id)

  defp location(_none),
    do: {:error, dgettext("dashboard_group_events", "Choose where the event takes place.")}

  defp location_id(kind, id) do
    case Shared.parse_optional_int(id) do
      id when is_integer(id) -> {:ok, {kind, id}}
      _invalid -> location(nil)
    end
  end

  defp registration_close(value, _timezone) when value in [nil, ""], do: {:ok, nil}

  defp registration_close(value, timezone) when is_binary(value) do
    with [date, time] <- String.split(value, "T", parts: 2),
         {:ok, date} <- Date.from_iso8601(date),
         {:ok, %Time{hour: hour, minute: minute}} <- Time.from_iso8601(seconds(time)),
         {:ok, closes_at} <- Shared.to_utc(date, hour, minute, timezone) do
      {:ok, DateTime.truncate(closes_at, :second)}
    else
      _invalid -> {:error, error_message(:invalid_registration_close)}
    end
  end

  defp seconds(time), do: if(String.length(time) == 5, do: time <> ":00", else: time)

  defp rate_limit(socket) do
    case Shared.check_quick_add_meeting_rate_limit(socket) do
      :ok ->
        :ok

      {:error, :rate_limited, _message} ->
        {:error,
         dgettext("dashboard_calendar_events", "Too many new meetings. Please wait a moment.")}
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp error_message(:start_in_past),
    do: dgettext("dashboard_group_events", "The event has to start in the future.")

  defp error_message(:invalid_registration_close),
    do:
      dgettext(
        "dashboard_group_events",
        "Registration has to close in the future, and no later than the event starts."
      )

  defp error_message(:time_conflict),
    do: dgettext("dashboard_group_events", "You already have a booking at that time.")

  defp error_message(:group_bookings_not_allowed),
    do: dgettext("dashboard_group_events", "Group events are not included in your plan.")

  defp error_message(_reason),
    do: dgettext("dashboard_group_events", "The event could not be created. Please try again.")
end
