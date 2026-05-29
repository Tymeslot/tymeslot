defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.EventCreate do
  @moduledoc "Event creation handlers for the calendar grid."

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, send_update: 2]

  require Logger

  alias Tymeslot.Bookings.CreateAdHoc
  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.ICalBuilder
  alias Tymeslot.Integrations.Calendar.Operations, as: EventOperations
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.MeetingProvisioning
  alias Tymeslot.Integrations.Video.EventDetails
  alias Tymeslot.Integrations.Video.Rooms, as: VideoRooms
  alias Tymeslot.Meetings.AttendeeNotifications
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
  @spec run_create_event(map()) :: {:ok, map()} | {:error, term(), map()}
  def run_create_event(payload) do
    %{creating: creating, user_id: user_id, start_at: start_at, end_at: end_at} = payload

    # Generate the UID upfront so both the provider write AND the offline
    # queue tag (on failure) reference the same identifier. CalDAV PUTs
    # with a caller-supplied UID are addressed by that UID server-side,
    # so a retry targets the same event.
    uid = ICalBuilder.generate_uid()

    # Canonical event-details shape used by the video provider and the
    # provisioning strategy. Times are merged from the resolved start_at/end_at
    # since they are only available after parsing the form dates.
    event_details =
      EventDetails.from_creating_form(
        Map.merge(creating, %{start_time: start_at, end_time: end_at})
      )

    # Decide how to attach a Google Meet link (if any). The "inline" strategy
    # piggybacks a `conferenceData.createRequest` onto the calendar create
    # itself (avoiding a duplicate event) when both the calendar and video
    # integrations point at the same Google account. The "separate" strategy
    # falls back to provisioning a Meet via the video provider, which writes
    # its own event to Google Calendar and surfaces the URL up-front.
    plan =
      MeetingProvisioning.plan(creating.integration_id, creating[:video_integration_id], user_id)

    video_context = provision_video_room_for_plan(plan, event_details, user_id)

    event_data =
      build_event_data(uid, creating, start_at, end_at, event_details, video_context, plan)

    result =
      calendar_operations_module().create_event(
        event_data,
        {creating.integration_id, user_id}
      )

    finalise_create_result(result, %{
      uid: uid,
      creating: creating,
      user_id: user_id,
      start_at: start_at,
      end_at: end_at,
      plan: plan,
      video_context: video_context
    })
  end

  defp build_event_data(uid, creating, start_at, end_at, event_details, video_context, plan) do
    description = build_description(creating[:description], video_context)

    raw_base = %{
      uid: uid,
      summary: creating.title,
      start_time: start_at,
      end_time: end_at,
      all_day: false,
      calendar_integration_id: creating.integration_id,
      calendar_id: creating[:calendar_id],
      description: description
    }

    base_data = MeetingProvisioning.attach_conference_data(raw_base, plan)

    attendees = Enum.map(event_details.attendees, fn a -> %{"email" => a.email} end)

    if attendees != [], do: Map.put(base_data, :attendees, attendees), else: base_data
  end

  defp finalise_create_result({:ok, created}, ctx) do
    case MeetingProvisioning.finalise(ctx.video_context, created, ctx.plan) do
      {:ok, video_context} ->
        build_create_success(
          created,
          ctx.creating,
          ctx.user_id,
          ctx.start_at,
          ctx.end_at,
          video_context
        )

      {:error, :no_meet_url, video_context} ->
        warning =
          "Google Calendar saved the event but didn't return a Meet link — " <>
            "please try again or add it manually."

        {:ok, result} =
          build_create_success(
            created,
            ctx.creating,
            ctx.user_id,
            ctx.start_at,
            ctx.end_at,
            video_context
          )

        {:ok, Map.put(result, :warning, warning)}
    end
  end

  defp finalise_create_result({:error, reason}, ctx) do
    # Carry context so the LiveView can tag the cache row for offline
    # retry. Use the pre-generated UID so a later retry reconciles to
    # the same cache entry.
    {:error, reason,
     %{
       uid: ctx.uid,
       calendar_integration_id: ctx.creating.integration_id,
       summary: ctx.creating.title,
       start_time: ctx.start_at,
       end_time: ctx.end_at,
       location: ctx.creating[:location],
       description: ctx.creating[:description]
     }}
  end

  defp provision_video_room_for_plan(:none, _event_details, _user_id), do: %{}
  defp provision_video_room_for_plan({:inline, _video_id}, _event_details, _user_id), do: %{}

  defp provision_video_room_for_plan({:separate, video_id}, event_details, user_id) do
    provision_video_room(video_id, user_id, event_details)
  end

  defp build_create_success(created, creating, user_id, start_at, end_at, video_context) do
    uid = if is_binary(created), do: created, else: created[:uid] || created["uid"]

    {provider, default_booking_calendar_id} = lookup_integration_metadata(creating.integration_id)
    meeting_url = video_context[:meeting_url]
    video_room_id = video_context[:room_id]

    notify_event = %{
      uid: uid,
      summary: creating.title,
      start_at: start_at,
      end_at: end_at,
      location: creating[:location],
      description: build_description(creating[:description], video_context),
      video_link: meeting_url,
      attendee_video_url: meeting_url,
      ical_sequence: 0,
      calendar_integration: %{user_id: user_id}
    }

    attendees =
      Enum.map(creating[:attendees] || [], fn email -> %{email: email} end)

    {:ok, _status} = AttendeeNotifications.event_created(notify_event, attendees)

    {:ok,
     %{
       uid: uid,
       creating: creating,
       start_at: start_at,
       end_at: end_at,
       provider: provider,
       default_booking_calendar_id: default_booking_calendar_id,
       attendees: attendees,
       meeting_url: meeting_url,
       video_room_id: video_room_id,
       description: notify_event.description
     }}
  end

  defp calendar_operations_module do
    Application.get_env(:tymeslot, :event_create_operations_module, EventOperations)
  end

  defp provision_video_room(integration_id, user_id, event_details)
       when is_integer(integration_id) do
    opts = [integration_id: integration_id, event_details: event_details]

    case VideoRooms.create_meeting_room(user_id, opts) do
      {:ok, %{room_data: room_data}} ->
        %{
          meeting_url: room_data[:meeting_url] || room_data[:join_url],
          room_id: room_data[:room_id],
          video_integration_id: integration_id
        }

      {:error, reason} ->
        Logger.warning("Failed to provision video room for new event",
          user_id: user_id,
          video_integration_id: integration_id,
          reason: inspect(reason)
        )

        %{}
    end
  end

  defp build_description(existing, video_context) do
    case video_context[:meeting_url] do
      nil ->
        existing

      url when is_binary(url) ->
        line = "Join video call: #{url}"

        case existing do
          nil -> line
          "" -> line
          text -> text <> "\n\n" <> line
        end
    end
  end

  defp lookup_integration_metadata(integration_id) do
    case CalendarIntegrationQueries.get(integration_id) do
      {:ok, integration} ->
        {integration.provider, integration.default_booking_calendar_id}

      {:error, :requires_reencryption, integration} ->
        CalendarManagement.handle_reauth_required(integration)

        send(
          self(),
          {:flash,
           {:error,
            "Your calendar needs to be reconnected. Please reconnect it from the Integrations page."}}
        )

        {nil, nil}

      {:error, _reason} ->
        {nil, nil}
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

    socket = put_flash(socket, :info, flash_for_create(attendees))

    socket =
      case result[:warning] do
        nil -> socket
        msg -> put_flash(socket, :warning, msg)
      end

    {:noreply, socket}
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
