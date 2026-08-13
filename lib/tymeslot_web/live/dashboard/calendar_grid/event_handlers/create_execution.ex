defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.CreateExecution do
  @moduledoc "Event creation save/result handlers for the calendar grid (presentation layer)."

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, send_update: 2]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.EventCreation
  alias Tymeslot.Integrations.Calendar.Operations, as: EventOperations
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared
  alias TymeslotWeb.Dashboard.CalendarGridComponent

  @spec handle_save_event(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_save_event(_params, socket) do
    creating = socket.assigns.creating_event

    if is_nil(creating) do
      {:noreply, socket}
    else
      handle_save_event_with(creating, socket)
    end
  end

  # Meeting mode books an ad-hoc Tymeslot meeting instead of writing a bare
  # provider event. A calendar integration is optional here: the booking is
  # native, and the provider copy is written back only when one is connected.
  defp handle_save_event_with(%{mode: :meeting} = creating, socket) do
    with :ok <- authorize_optional_integration(socket, creating[:integration_id]),
         {:ok, start_at, end_at} <- resolve_timed_range(creating, socket),
         :ok <- validate_meeting_fields(creating, socket.assigns.current_user.email) do
      send(
        self(),
        {:execute_create_ad_hoc_meeting, ad_hoc_params(creating, socket, start_at, end_at)}
      )

      {:noreply, assign(socket, :saving_event, true)}
    else
      {:error, message} when is_binary(message) ->
        send(self(), {:flash, {:error, message}})
        {:noreply, socket}

      {:error, :unauthorized} ->
        send(
          self(),
          {:flash, {:error, dgettext("dashboard_calendar_events", "Invalid calendar selected")}}
        )

        {:noreply, socket}
    end
  end

  # Authorize the create against the user's own integrations before doing any
  # work. `owned_integration_ids` is the same MapSet that gates move/resize/
  # delete via `EditWorkflow.assert_owns_event/2`; routing creation through it
  # keeps authorization defensive at the handler level rather than relying on
  # the form only ever offering owned calendars.
  defp handle_save_event_with(creating, socket) do
    case EditWorkflow.assert_owns_integration(socket, creating.integration_id) do
      {:error, :unauthorized} ->
        send(
          self(),
          {:flash, {:error, dgettext("dashboard_calendar_events", "Invalid calendar selected")}}
        )

        {:noreply, socket}

      :ok ->
        with {:ok, start_date} <- Date.from_iso8601(creating.date),
             {:ok, end_date} <- Date.from_iso8601(creating.end_date) do
          save_resolved(creating, start_date, end_date, socket)
        else
          {:error, _reason} ->
            send(
              self(),
              {:flash, {:error, dgettext("dashboard_calendar_events", "Invalid date")}}
            )

            {:noreply, socket}
        end
    end
  end

  # Builds the payload the async ad-hoc booking path consumes. An untitled
  # meeting falls back to naming the guest, which is what the organiser will
  # recognise it by on the grid.
  defp ad_hoc_params(creating, socket, start_at, end_at) do
    guest_name = String.trim(creating.guest_name)

    title =
      case String.trim(creating.title || "") do
        "" -> dgettext("dashboard_calendar_events", "Meeting with %{name}", name: guest_name)
        custom -> custom
      end

    %{
      title: title,
      start_time: start_at,
      end_time: end_at,
      attendee_name: guest_name,
      attendee_email: String.trim(creating.guest_email),
      attendee_timezone: socket.assigns.user_timezone,
      organizer_user_id: socket.assigns.current_user.id,
      calendar_integration_id: creating[:integration_id],
      calendar_id: creating[:calendar_id],
      video_integration_id: creating[:video_integration_id]
    }
  end

  # All-day events round-trip start/end as Dates (and `all_day: true`) so the
  # provider mappers emit date-only values. Timed events resolve to UTC
  # datetimes in the user's timezone.
  #
  # The form's end date is the inclusive last day the user picked; storage and
  # the provider mappers expect an exclusive `end_date` (iCal `DTEND;VALUE=DATE`
  # / Google `end.date` are both exclusive), so a single-day all-day event is
  # written as `end_date = start_date + 1`.
  defp save_resolved(%{all_day: true} = creating, start_date, end_date, socket) do
    if Date.compare(end_date, start_date) == :lt do
      send(
        self(),
        {:flash,
         {:error, dgettext("dashboard_calendar_events", "End date must not be before start date")}}
      )

      {:noreply, socket}
    else
      send(
        self(),
        {:execute_create_event,
         %{
           creating: creating,
           user_id: socket.assigns.current_user.id,
           all_day: true,
           start_at: start_date,
           end_at: Date.add(end_date, 1)
         }}
      )

      {:noreply, assign(socket, :saving_event, true)}
    end
  end

  defp save_resolved(creating, start_date, end_date, socket) do
    tz = socket.assigns.user_timezone

    with {:ok, start_at} <-
           Shared.to_utc(start_date, creating.start_hour, creating.start_minute, tz),
         {:ok, end_at} <-
           Shared.to_utc(end_date, creating.end_hour, creating.end_minute, tz) do
      if DateTime.compare(end_at, start_at) != :gt do
        send(
          self(),
          {:flash,
           {:error, dgettext("dashboard_calendar_events", "End time must be after start time")}}
        )

        {:noreply, socket}
      else
        send(
          self(),
          {:execute_create_event,
           %{
             creating: creating,
             user_id: socket.assigns.current_user.id,
             all_day: false,
             start_at: start_at,
             end_at: end_at
           }}
        )

        {:noreply, assign(socket, :saving_event, true)}
      end
    else
      {:error, _reason} ->
        send(self(), {:flash, {:error, dgettext("dashboard_calendar_events", "Invalid time")}})
        {:noreply, socket}
    end
  end

  @doc false
  @spec handle_create_result(
          {:ok, map()} | {:error, term()} | {:error, term(), map()},
          Phoenix.LiveView.Socket.t()
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_create_result({:ok, result}, socket) do
    %{
      uid: uid,
      creating: creating,
      start_at: start_at,
      end_at: end_at,
      provider: provider,
      default_booking_calendar_id: default_booking_calendar_id,
      attendees: attendees,
      meeting_url: meeting_url,
      description: description
    } = result

    provider_calendar_id =
      creating[:calendar_id] || default_booking_calendar_id || "primary"

    all_day = Map.get(creating, :all_day, false)

    timing = cache_timing(all_day, start_at, end_at)

    CalendarGrid.cache_created_event(
      Map.merge(timing, %{
        uid: uid,
        calendar_integration_id: creating.integration_id,
        provider: provider,
        provider_calendar_id: provider_calendar_id,
        summary: creating.title,
        description: description,
        all_day: all_day,
        reminders: Map.get(creating, :reminders, []),
        recurrence_rule: Map.get(creating, :recurrence_rule),
        video_link: meeting_url,
        video_integration_id: creating[:video_integration_id]
      })
    )

    send_update(CalendarGridComponent,
      id: "calendar",
      action: :event_created
    )

    socket
    |> put_flash(:info, flash_for_create(attendees))
    |> maybe_flash_warning(result[:warning])
    |> maybe_flash_reauth(result[:reauth_required])
    |> then(&{:noreply, &1})
  end

  def handle_create_result({:error, _reason, context}, socket) when is_map(context) do
    # For CalDAV integrations, tag a placeholder cache row so the next
    # OfflineQueue flush retries the create. A :ok return means the row
    # is queued; :ignored means the integration is non-CalDAV and has
    # no offline queue support, so the failure is final.
    meeting = %{
      uid: context.uid,
      calendar_integration_id: context.calendar_integration_id
    }

    queue_result = EventOperations.tag_for_offline_retry(meeting, :create, context)

    send_update(CalendarGridComponent,
      id: "calendar",
      action: :event_create_failed
    )

    flash_message =
      case queue_result do
        :ok ->
          dgettext("dashboard_calendar_events", "Create failed - queued to retry on next sync")

        :ignored ->
          dgettext("dashboard_calendar_events", "Failed to create event")
      end

    {:noreply, put_flash(socket, :error, flash_message)}
  end

  def handle_create_result({:error, _reason}, socket) do
    # Fallback for contextless failures.
    send_update(CalendarGridComponent,
      id: "calendar",
      action: :event_create_failed
    )

    {:noreply,
     put_flash(socket, :error, dgettext("dashboard_calendar_events", "Failed to create event"))}
  end

  # An ad-hoc meeting may be created with no integration at all; when one is
  # selected it must be the user's own.
  defp authorize_optional_integration(_socket, nil), do: :ok

  defp authorize_optional_integration(socket, integration_id),
    do: EditWorkflow.assert_owns_integration(socket, integration_id)

  defp resolve_timed_range(creating, socket) do
    tz = socket.assigns.user_timezone

    with {:ok, start_date} <- parse_date(creating.date),
         {:ok, end_date} <- parse_date(creating.end_date),
         {:ok, start_at} <-
           to_utc_or_error(start_date, creating.start_hour, creating.start_minute, tz),
         {:ok, end_at} <- to_utc_or_error(end_date, creating.end_hour, creating.end_minute, tz) do
      if DateTime.compare(end_at, start_at) == :gt do
        {:ok, start_at, end_at}
      else
        {:error, dgettext("dashboard_calendar_events", "End time must be after start time")}
      end
    end
  end

  defp parse_date(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, dgettext("dashboard_calendar_events", "Invalid date")}
    end
  end

  defp to_utc_or_error(date, hour, minute, tz) do
    case Shared.to_utc(date, hour, minute, tz) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, dgettext("dashboard_calendar_events", "Invalid time")}
    end
  end

  # The self-booking rule is enforced authoritatively by `Bookings.CreateAdHoc`,
  # which compares against the stored organiser address. Repeating it here buys
  # a translated message on the form rather than a flash after the round trip.
  defp validate_meeting_fields(creating, organizer_email) do
    guest_email = String.trim(creating.guest_email)

    cond do
      String.trim(creating.guest_name) == "" ->
        {:error, dgettext("dashboard_calendar_events", "Guest name is required")}

      not Shared.valid_email?(guest_email) ->
        {:error, dgettext("dashboard_calendar_events", "A valid guest email is required")}

      same_address?(guest_email, organizer_email) ->
        {:error,
         dgettext(
           "dashboard_calendar_events",
           "You cannot add yourself as a guest. Use a different email address."
         )}

      true ->
        :ok
    end
  end

  defp same_address?(guest_email, organizer_email) when is_binary(organizer_email) do
    String.downcase(guest_email) == organizer_email |> String.trim() |> String.downcase()
  end

  defp same_address?(_guest_email, _organizer_email), do: false

  # All-day events store `start_date`/`end_date` (the cache row leaves
  # `start_at`/`end_at` null); timed events store `start_at`/`end_at`.
  defp cache_timing(true, %Date{} = start_date, %Date{} = end_date),
    do: %{start_date: start_date, end_date: end_date}

  defp cache_timing(_all_day, start_at, end_at),
    do: %{start_at: start_at, end_at: end_at}

  defp maybe_flash_warning(socket, nil), do: socket
  defp maybe_flash_warning(socket, msg), do: put_flash(socket, :warning, msg)

  # The domain layer signals — via data, since it runs in a Task — that the
  # integration's credentials need re-encrypting. Surface the reconnect flash
  # here, in the LiveView process, where it actually reaches the user.
  defp maybe_flash_reauth(socket, true) do
    put_flash(socket, :error, EventCreation.reauth_flash_message())
  end

  defp maybe_flash_reauth(socket, _other), do: socket

  defp flash_for_create([]), do: dgettext("dashboard_calendar_events", "Event created.")

  defp flash_for_create(_attendees),
    do: dgettext("dashboard_calendar_events", "Event created. Attendees have been invited.")
end
