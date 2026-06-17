defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.EventCreate do
  @moduledoc "Event creation form handlers for the calendar grid (presentation layer)."

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, send_update: 2]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.EventCreation
  alias Tymeslot.Integrations.Calendar.Operations, as: EventOperations
  alias Tymeslot.Security.UniversalSanitizer
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared
  alias TymeslotWeb.Dashboard.CalendarGridComponent

  @spec handle_show_create_form(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_show_create_form(params, socket) do
    with {:ok, start_hour} <- Shared.parse_int(params["start-hour"]),
         {:ok, start_minute} <- Shared.parse_int(params["start-minute"]),
         {:ok, end_hour} <- Shared.parse_int(params["end-hour"]),
         {:ok, end_minute} <- Shared.parse_int(params["end-minute"]) do
      default_int_id = EditWorkflow.default_integration_id(socket)

      end_date = params["end-date"] || params["date"]

      creating = %{
        date: params["date"],
        end_date: end_date,
        start_hour: start_hour,
        start_minute: start_minute,
        end_hour: end_hour,
        end_minute: end_minute,
        title: "",
        integration_id: default_int_id,
        calendar_id:
          EditWorkflow.default_calendar_id(socket.assigns.integrations, default_int_id),
        attendees: [],
        attendee_input: "",
        video_integration_id: nil
      }

      {:noreply, assign(socket, :creating_event, creating)}
    else
      :error -> {:noreply, socket}
    end
  end

  @spec handle_close_create_form(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_close_create_form(_params, socket) do
    creating = socket.assigns.creating_event

    if creating && creating.attendees != [] do
      {:noreply, assign(socket, :confirm_discard_attendees, true)}
    else
      {:noreply, assign(socket, :creating_event, nil)}
    end
  end

  @spec handle_update_create_title(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_create_title(%{"value" => title}, socket) do
    case socket.assigns.creating_event do
      nil ->
        {:noreply, socket}

      creating_event ->
        case UniversalSanitizer.sanitize_and_validate(title, mode: :plain_text, max_length: 500) do
          {:ok, sanitised} ->
            creating = Map.put(creating_event, :title, sanitised)
            {:noreply, assign(socket, :creating_event, creating)}

          {:error, _reason} ->
            {:noreply, socket}
        end
    end
  end

  @spec handle_update_create_time(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_create_time(params, socket) do
    case socket.assigns.creating_event do
      nil ->
        {:noreply, socket}

      creating ->
        updated =
          creating
          |> maybe_update_date(params["start-date"], :date)
          |> maybe_update_date(params["end-date"], :end_date)
          |> maybe_update_time(params["start-time"], :start_hour, :start_minute)
          |> maybe_update_time(params["end-time"], :end_hour, :end_minute)

        {:noreply, assign(socket, :creating_event, updated)}
    end
  end

  @spec handle_update_create_integration(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_create_integration(params, socket) do
    id_str = params["integration-id"] || params["integration_id"]
    cal_id = params["calendar-id"]

    case Shared.parse_int(id_str) do
      {:ok, id} ->
        creating =
          socket.assigns.creating_event
          |> Map.put(:integration_id, id)
          |> Map.put(
            :calendar_id,
            cal_id || EditWorkflow.default_calendar_id(socket.assigns.integrations, id)
          )

        {:noreply, assign(socket, :creating_event, creating)}

      :error ->
        {:noreply, socket}
    end
  end

  @spec handle_add_create_attendee(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_add_create_attendee(%{"email" => raw_email}, socket) do
    creating = socket.assigns.creating_event

    if is_nil(creating) do
      {:noreply, socket}
    else
      email = raw_email |> String.trim() |> String.downcase()

      if Shared.valid_email?(email) and email not in creating.attendees do
        updated =
          creating
          |> Map.put(:attendees, creating.attendees ++ [email])
          |> Map.put(:attendee_input, "")

        {:noreply, assign(socket, :creating_event, updated)}
      else
        {:noreply, socket}
      end
    end
  end

  @spec handle_remove_create_attendee(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_remove_create_attendee(%{"email" => email}, socket) do
    creating = socket.assigns.creating_event

    if is_nil(creating) do
      {:noreply, socket}
    else
      updated = Map.put(creating, :attendees, List.delete(creating.attendees, email))
      {:noreply, assign(socket, :creating_event, updated)}
    end
  end

  @spec handle_update_create_attendee_input(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_create_attendee_input(%{"email" => value}, socket) do
    creating = socket.assigns.creating_event

    if is_nil(creating) do
      {:noreply, socket}
    else
      {:noreply, assign(socket, :creating_event, Map.put(creating, :attendee_input, value))}
    end
  end

  @spec handle_update_create_video(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_create_video(params, socket) do
    creating = socket.assigns.creating_event

    if is_nil(creating) do
      {:noreply, socket}
    else
      updated = maybe_put_int(creating, :video_integration_id, params["video_integration_id"])
      {:noreply, assign(socket, :creating_event, updated)}
    end
  end

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

  defp handle_save_event_with(creating, socket) do
    integration = Enum.find(socket.assigns.integrations, &(&1.id == creating.integration_id))

    if is_nil(integration) do
      send(self(), {:flash, {:error, "Invalid calendar selected"}})
      {:noreply, socket}
    else
      tz = socket.assigns.user_timezone

      with {:ok, start_date} <- Date.from_iso8601(creating.date),
           {:ok, end_date} <- Date.from_iso8601(creating.end_date) do
        start_at = Shared.to_utc(start_date, creating.start_hour, creating.start_minute, tz)
        end_at = Shared.to_utc(end_date, creating.end_hour, creating.end_minute, tz)

        if DateTime.compare(end_at, start_at) != :gt do
          send(self(), {:flash, {:error, "End time must be after start time"}})
          {:noreply, socket}
        else
          send(
            self(),
            {:execute_create_event,
             %{
               creating: creating,
               user_id: socket.assigns.current_user.id,
               start_at: start_at,
               end_at: end_at
             }}
          )

          {:noreply, assign(socket, :saving_event, true)}
        end
      else
        {:error, _reason} ->
          send(self(), {:flash, {:error, "Invalid date"}})
          {:noreply, socket}
      end
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

    CalendarGrid.cache_created_event(%{
      uid: uid,
      calendar_integration_id: creating.integration_id,
      provider: provider,
      provider_calendar_id: provider_calendar_id,
      summary: creating.title,
      description: description,
      start_at: start_at,
      end_at: end_at,
      all_day: false,
      video_link: meeting_url,
      video_integration_id: creating[:video_integration_id]
    })

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
        :ok -> "Create failed — queued to retry on next sync"
        :ignored -> "Failed to create event"
      end

    {:noreply, put_flash(socket, :error, flash_message)}
  end

  def handle_create_result({:error, _reason}, socket) do
    # Fallback for contextless failures.
    send_update(CalendarGridComponent,
      id: "calendar",
      action: :event_create_failed
    )

    {:noreply, put_flash(socket, :error, "Failed to create event")}
  end

  defp maybe_flash_warning(socket, nil), do: socket
  defp maybe_flash_warning(socket, msg), do: put_flash(socket, :warning, msg)

  # The domain layer signals — via data, since it runs in a Task — that the
  # integration's credentials need re-encrypting. Surface the reconnect flash
  # here, in the LiveView process, where it actually reaches the user.
  defp maybe_flash_reauth(socket, true) do
    put_flash(socket, :error, EventCreation.reauth_flash_message())
  end

  defp maybe_flash_reauth(socket, _other), do: socket

  defp maybe_update_date(creating, date_str, key)
       when is_binary(date_str) and date_str != "" do
    case Date.from_iso8601(date_str) do
      {:ok, _date} -> Map.put(creating, key, date_str)
      {:error, _reason} -> creating
    end
  end

  defp maybe_update_date(creating, _date_str, _key), do: creating

  defp maybe_update_time(creating, time_str, hour_key, minute_key)
       when is_binary(time_str) and time_str != "" do
    case String.split(time_str, ":") do
      [h, m | _rest] ->
        with {hour, ""} <- Integer.parse(h),
             {minute, ""} <- Integer.parse(m) do
          creating
          |> Map.put(hour_key, hour)
          |> Map.put(minute_key, minute)
        else
          _invalid -> creating
        end

      _invalid ->
        creating
    end
  end

  defp maybe_update_time(creating, _time_str, _hour_key, _minute_key), do: creating

  defp flash_for_create([]), do: "Event created."
  defp flash_for_create(_attendees), do: "Event created. Attendees have been invited."

  defp maybe_put_int(map, _key, nil), do: map
  defp maybe_put_int(map, key, ""), do: Map.put(map, key, nil)

  defp maybe_put_int(map, key, val) when is_binary(val) do
    case Integer.parse(val) do
      {int, ""} -> Map.put(map, key, int)
      _other -> map
    end
  end
end
