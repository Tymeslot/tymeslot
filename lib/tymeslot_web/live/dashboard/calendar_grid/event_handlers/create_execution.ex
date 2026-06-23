defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.CreateExecution do
  @moduledoc "Event creation save/result handlers for the calendar grid (presentation layer)."

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, send_update: 2]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.EventCreation
  alias Tymeslot.Integrations.Calendar.Operations, as: EventOperations
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

  defp flash_for_create([]), do: "Event created."
  defp flash_for_create(_attendees), do: "Event created. Attendees have been invited."
end
