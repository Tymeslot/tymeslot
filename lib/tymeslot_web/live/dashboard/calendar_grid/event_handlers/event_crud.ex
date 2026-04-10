defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.EventCrud do
  @moduledoc "Create, delete, and recurrence event handlers for CalendarGridComponent."

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, send_update: 2]

  alias Tymeslot.Bookings.CreateAdHoc
  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.Operations, as: EventOperations
  alias Tymeslot.Notifications.Orchestrator
  alias Tymeslot.Security.UniversalSanitizer
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers
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
        case UniversalSanitizer.sanitize_and_validate(title, max_length: 500) do
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
  @spec run_create_event(map()) :: {:ok, map()} | {:error, term()}
  def run_create_event(payload) do
    %{creating: creating, user_id: user_id, start_at: start_at, end_at: end_at} = payload

    attendees = Enum.map(creating[:attendees] || [], fn email -> %{"email" => email} end)

    base_data = %{
      summary: creating.title,
      start_time: start_at,
      end_time: end_at,
      all_day: false,
      calendar_integration_id: creating.integration_id,
      calendar_id: creating[:calendar_id]
    }

    event_data =
      if attendees != [], do: Map.put(base_data, :attendees, attendees), else: base_data

    result = EventOperations.create_event(event_data, {creating.integration_id, user_id})

    case result do
      {:ok, created} ->
        uid = if is_binary(created), do: created, else: created[:uid] || created["uid"]

        Orchestrator.schedule_calendar_invitations(
          user_id,
          creating[:attendees] || [],
          %{
            title: creating.title,
            uid: uid,
            start_at: start_at,
            end_at: end_at,
            location: creating[:location],
            description: creating[:description]
          }
        )

        {:ok, %{uid: uid, creating: creating, start_at: start_at, end_at: end_at}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec run_create_ad_hoc_meeting(map()) :: {:ok, map()} | {:error, term()}
  def run_create_ad_hoc_meeting(params) do
    ad_hoc_params = %{
      title: params.title,
      start_time: params.start_time,
      end_time: params.end_time,
      attendee_name: params.attendee_name,
      attendee_email: params.attendee_email,
      attendee_timezone: params[:attendee_timezone] || "Etc/UTC",
      organizer_user_id: params.organizer_user_id,
      calendar_integration_id: params[:calendar_integration_id],
      calendar_path: params[:calendar_id],
      video_integration_id: params[:video_integration_id]
    }

    case CreateAdHoc.execute(ad_hoc_params) do
      {:ok, meeting} ->
        {:ok, %{meeting_id: meeting.id, start_at: params.start_time, end_at: params.end_time}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec handle_create_result({:ok, map()} | {:error, term()}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_create_result(
        {:ok, %{uid: uid, creating: creating, start_at: start_at, end_at: end_at}},
        socket
      ) do
    integration =
      Enum.find(socket.assigns.integrations, &(&1.id == creating.integration_id))

    provider = integration && integration.provider

    provider_calendar_id =
      creating[:calendar_id] ||
        (integration && integration.default_booking_calendar_id) ||
        "primary"

    CalendarGrid.cache_created_event(%{
      uid: uid,
      calendar_integration_id: creating.integration_id,
      provider: provider,
      provider_calendar_id: provider_calendar_id,
      summary: creating.title,
      start_at: start_at,
      end_at: end_at,
      all_day: false
    })

    send_update(CalendarGridComponent,
      id: "calendar",
      action: :event_created
    )

    {:noreply, socket}
  end

  def handle_create_result({:error, _reason}, socket) do
    send_update(CalendarGridComponent,
      id: "calendar",
      action: :event_create_failed
    )

    {:noreply, put_flash(socket, :error, "Failed to create event")}
  end

  @spec handle_request_delete_event(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_request_delete_event(_params, socket) do
    case socket.assigns.selected_event do
      nil ->
        {:noreply, socket}

      event ->
        case EditWorkflow.assert_owns_event(socket, event) do
          :ok ->
            linked_to_booking =
              EventOperations.event_linked_to_booking?(
                event.calendar_integration_id,
                event.provider_event_id,
                event.uid
              )

            socket =
              socket
              |> assign(:selected_event, nil)
              |> assign(:confirm_delete_event, event)
              |> assign(:confirm_delete_linked_to_booking, linked_to_booking)

            {:noreply, socket}

          {:error, :unauthorized} ->
            send(self(), {:flash, {:error, "You don't have permission to delete this event"}})
            {:noreply, socket}
        end
    end
  end

  @spec handle_confirm_delete_event(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_confirm_delete_event(_params, socket) do
    case socket.assigns.confirm_delete_event do
      nil ->
        {:noreply, socket}

      event ->
        case Shared.check_edit_rate_limit(socket) do
          :ok ->
            send(
              self(),
              {:execute_delete_event,
               %{
                 uid: event.uid,
                 provider_event_id: event.provider_event_id,
                 calendar_integration_id: event.calendar_integration_id,
                 user_id: socket.assigns.current_user.id
               }}
            )

            {:noreply, assign(socket, :deleting_event, true)}

          {:error, :rate_limited, _message} ->
            send(self(), {:flash, {:warning, "Too many edits. Please wait a moment."}})
            {:noreply, assign(socket, :confirm_delete_event, nil)}
        end
    end
  end

  @doc false
  @spec run_delete_event(map()) :: {:ok, map()} | {:error, term()}
  def run_delete_event(payload) do
    %{uid: uid, calendar_integration_id: integration_id, user_id: user_id} = payload

    opts =
      if payload[:provider_event_id], do: [provider_event_id: payload.provider_event_id], else: []

    EventOperations.delete_event_and_reconcile(
      uid,
      payload[:provider_event_id],
      {integration_id, user_id},
      opts
    )
  end

  @doc false
  @spec handle_delete_result({:ok, map()} | {:error, term()}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_delete_result({:ok, %{uid: uid, integration_id: integration_id} = result}, socket) do
    CalendarGrid.delete_cached_event(integration_id, uid)

    send_update(CalendarGridComponent,
      id: "calendar",
      action: :event_deleted
    )

    socket =
      case result do
        %{reconcile_result: :ok, meeting_attendee_email: _email_ok} ->
          put_flash(socket, :info, "Event and linked meeting cancelled.")

        %{reconcile_result: {:error, _reason}, meeting_attendee_email: _email_err} ->
          put_flash(
            socket,
            :error,
            "Event deleted, but meeting cancellation failed. The attendee may not be notified."
          )

        _no_meeting ->
          socket
      end

    {:noreply, socket}
  end

  def handle_delete_result({:error, _reason}, socket) do
    send_update(CalendarGridComponent,
      id: "calendar",
      action: :event_delete_failed
    )

    {:noreply, put_flash(socket, :error, "Failed to delete event")}
  end

  @spec handle_cancel_delete_event(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_cancel_delete_event(_params, socket) do
    {:noreply,
     socket
     |> assign(:confirm_delete_event, nil)
     |> assign(:confirm_delete_linked_to_booking, false)}
  end

  @spec handle_confirm_recurrence_scope(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_confirm_recurrence_scope(%{"scope" => scope}, socket) do
    case socket.assigns.recurrence_prompt do
      nil ->
        {:noreply, socket}

      prompt ->
        socket = assign(socket, :recurrence_prompt, nil)

        socket =
          EditWorkflow.update_event_async(
            socket,
            prompt.event,
            prompt.optimistic_event,
            prompt.new_start,
            prompt.new_end,
            recurrence_scope: scope
          )

        {:noreply, socket}
    end
  end

  @spec handle_cancel_recurrence_prompt(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_cancel_recurrence_prompt(_params, socket) do
    case socket.assigns.recurrence_prompt do
      nil ->
        {:noreply, socket}

      prompt ->
        reverted_events =
          Enum.map(socket.assigns.events, fn e ->
            if e.id == prompt.original_event.id, do: prompt.original_event, else: e
          end)

        socket =
          socket
          |> assign(:recurrence_prompt, nil)
          |> assign(:events, reverted_events)
          |> Helpers.precompute_derived()

        {:noreply, socket}
    end
  end

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

  defp maybe_put_int(map, _key, nil), do: map
  defp maybe_put_int(map, key, ""), do: Map.put(map, key, nil)

  defp maybe_put_int(map, key, val) when is_binary(val) do
    case Integer.parse(val) do
      {int, ""} -> Map.put(map, key, int)
      _other -> map
    end
  end
end
