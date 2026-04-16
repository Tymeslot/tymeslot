defmodule TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow do
  @moduledoc "Drag, resize, create, and inline-edit workflow functions for CalendarGridComponent."

  require Logger

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.Operations, as: EventOperations
  alias Tymeslot.Integrations.Video.Rooms, as: VideoRooms
  alias Tymeslot.Meetings.AttendeeNotifications
  alias Tymeslot.Meetings.AttendeeNotifications.ChangeSummary
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers

  @spec default_integration_id(Phoenix.LiveView.Socket.t()) :: integer() | nil
  def default_integration_id(socket) do
    case socket.assigns.integrations do
      [first | _rest] -> first.id
      [] -> nil
    end
  end

  @spec default_calendar_id(list(), integer() | nil) :: String.t() | nil
  def default_calendar_id(_integrations, nil), do: nil

  def default_calendar_id(integrations, integration_id) do
    case Enum.find(integrations, &(&1.id == integration_id)) do
      nil -> nil
      integration -> default_calendar_id_for(integration)
    end
  end

  @spec default_calendar_id_for(map()) :: String.t() | nil
  def default_calendar_id_for(integration) do
    integration.default_booking_calendar_id ||
      find_primary_calendar_id(integration.calendar_list)
  end

  defp find_primary_calendar_id(nil), do: nil
  defp find_primary_calendar_id([]), do: nil

  defp find_primary_calendar_id(calendar_list) do
    primary = Enum.find(calendar_list, &(&1["primary"] || &1[:primary]))
    selected = primary || Enum.find(calendar_list, &(&1["selected"] || &1[:selected]))
    cal = selected || List.first(calendar_list)
    cal["id"] || cal[:id]
  end

  @spec format_create_time(map()) :: String.t()
  def format_create_time(creating) do
    "#{format_time_value(creating.start_hour, creating.start_minute)} \u2013 #{format_time_value(creating.end_hour, creating.end_minute)}"
  end

  @spec format_time_value(integer(), integer()) :: String.t()
  def format_time_value(hour, minute) do
    "#{String.pad_leading("#{hour}", 2, "0")}:#{String.pad_leading("#{minute}", 2, "0")}"
  end

  @spec with_editable_event(Phoenix.LiveView.Socket.t(), map(), function()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def with_editable_event(socket, params, fun) do
    case Integer.parse(params["event-id"] || "") do
      {event_id, ""} ->
        event = Enum.find(socket.assigns.events, &(&1.id == event_id))

        cond do
          is_nil(event) ->
            {:noreply, socket}

          assert_owns_event(socket, event) == {:error, :unauthorized} ->
            send(self(), {:flash, {:error, "You don't have permission to modify this event"}})
            {:noreply, socket}

          true ->
            {:noreply, fun.(event)}
        end

      _invalid ->
        {:noreply, socket}
    end
  end

  @spec apply_event_change(Phoenix.LiveView.Socket.t(), map(), map(), DateTime.t(), DateTime.t()) ::
          Phoenix.LiveView.Socket.t()
  def apply_event_change(socket, event, optimistic_event, new_start, new_end) do
    original_events = socket.assigns.events

    new_events =
      Enum.map(original_events, fn e ->
        if e.id == event.id, do: optimistic_event, else: e
      end)

    socket =
      socket
      |> assign(:events, new_events)
      |> Helpers.precompute_derived()

    if event.recurring_event_id do
      prompt = %{
        event: event,
        optimistic_event: optimistic_event,
        new_start: new_start,
        new_end: new_end,
        original_event: event
      }

      assign(socket, :recurrence_prompt, prompt)
    else
      update_event_async(socket, event, optimistic_event, new_start, new_end)
    end
  end

  @spec assert_owns_event(Phoenix.LiveView.Socket.t(), map()) :: :ok | {:error, :unauthorized}
  def assert_owns_event(socket, event) do
    if MapSet.member?(socket.assigns.owned_integration_ids, event.calendar_integration_id) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  @spec update_event_async(
          Phoenix.LiveView.Socket.t(),
          map(),
          map(),
          DateTime.t(),
          DateTime.t(),
          keyword()
        ) ::
          Phoenix.LiveView.Socket.t()
  def update_event_async(socket, original_event, optimistic_event, new_start, new_end, opts \\ []) do
    recurrence_scope = Keyword.get(opts, :recurrence_scope)
    user_id = socket.assigns.current_user.id
    lv_pid = self()

    base_event_data = %{
      summary: optimistic_event.summary || "",
      start_time: new_start,
      end_time: new_end,
      description: optimistic_event.description || original_event.description || "",
      location: optimistic_event.location || original_event.location || "",
      provider_event_id: original_event.provider_event_id
    }

    event_data =
      if recurrence_scope do
        Map.put(base_event_data, :recurrence_scope, recurrence_scope)
      else
        base_event_data
      end

    Task.Supervisor.start_child(Tymeslot.TaskSupervisor, fn ->
      result =
        EventOperations.update_event(
          original_event.uid,
          event_data,
          {original_event.calendar_integration_id, user_id}
        )

      case result do
        :ok ->
          timing =
            if optimistic_event.all_day do
              %{start_date: optimistic_event.start_date, end_date: optimistic_event.end_date}
            else
              %{start_at: new_start, end_at: new_end}
            end

          CalendarGrid.update_cached_event(
            Map.merge(timing, %{
              uid: original_event.uid,
              calendar_integration_id: original_event.calendar_integration_id,
              provider: original_event.provider,
              provider_calendar_id: original_event.provider_calendar_id,
              provider_event_id: original_event.provider_event_id,
              summary: optimistic_event.summary,
              all_day: optimistic_event.all_day,
              location: optimistic_event.location || original_event.location,
              description: optimistic_event.description || original_event.description,
              attendees: original_event.attendees || [],
              status: original_event.status,
              provider_metadata: original_event.provider_metadata,
              synced_at: DateTime.utc_now(:second)
            })
          )

          send(lv_pid, {:event_update_result, :ok})

        {:error, reason} ->
          send(
            lv_pid,
            {:event_update_result, {:error, original_event: original_event, reason: reason}}
          )
      end
    end)

    socket
  end

  @spec update_field_async(Phoenix.LiveView.Socket.t(), map(), atom(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def update_field_async(socket, original_event, field, new_value)
      when field in [:summary, :location, :description] do
    user_id = socket.assigns.current_user.id
    lv_pid = self()
    event_data = build_field_event_data(original_event, field, new_value)
    cache_row = build_field_cache_row(original_event, field, new_value)

    Task.Supervisor.start_child(Tymeslot.TaskSupervisor, fn ->
      result =
        EventOperations.update_event(
          original_event.uid,
          event_data,
          {original_event.calendar_integration_id, user_id}
        )

      case result do
        :ok ->
          CalendarGrid.update_cached_event(cache_row)
          send(lv_pid, {:event_update_result, :ok})

        {:error, reason} ->
          send(
            lv_pid,
            {:event_update_result, {:error, original_event: original_event, reason: reason}}
          )
      end
    end)

    socket
  end

  @doc """
  Moves an event from one integration to another via delete + create.
  Runs asynchronously; sends `{:event_move_result, ...}` to the LiveView.
  """
  @spec move_event_async(Phoenix.LiveView.Socket.t(), map(), integer()) ::
          Phoenix.LiveView.Socket.t()
  @spec move_event_async(Phoenix.LiveView.Socket.t(), map(), integer(), keyword()) ::
          Phoenix.LiveView.Socket.t()
  def move_event_async(socket, event, new_integration_id, opts \\ []) do
    user_id = socket.assigns.current_user.id
    lv_pid = self()
    new_calendar_id = opts[:calendar_id]

    new_integration = Enum.find(socket.assigns.integrations, &(&1.id == new_integration_id))

    new_provider = new_integration && new_integration.provider

    new_provider_calendar_id =
      new_calendar_id ||
        (new_integration && new_integration.default_booking_calendar_id) ||
        "primary"

    event_attrs = %{
      summary: event.summary || "",
      start_time: event.start_at,
      end_time: event.end_at,
      description: event.description || "",
      location: event.location || "",
      all_day: event.all_day || false,
      calendar_id: new_calendar_id
    }

    delete_opts =
      if event.provider_event_id,
        do: [provider_event_id: event.provider_event_id],
        else: []

    Task.Supervisor.start_child(Tymeslot.TaskSupervisor, fn ->
      with :ok <-
             EventOperations.delete_event(
               event.uid,
               {event.calendar_integration_id, user_id},
               delete_opts
             ),
           {:ok, created} <-
             EventOperations.create_event(
               Map.put(event_attrs, :calendar_integration_id, new_integration_id),
               {new_integration_id, user_id}
             ) do
        CalendarGrid.delete_cached_event(event.calendar_integration_id, event.uid)

        uid = if is_binary(created), do: created, else: created[:uid] || created["uid"]

        timing =
          if event.all_day do
            %{start_date: event.start_date, end_date: event.end_date}
          else
            %{start_at: event.start_at, end_at: event.end_at}
          end

        CalendarGrid.cache_created_event(
          Map.merge(timing, %{
            uid: uid,
            calendar_integration_id: new_integration_id,
            provider: new_provider,
            provider_calendar_id: new_provider_calendar_id,
            summary: event.summary,
            all_day: event.all_day || false
          })
        )

        send(lv_pid, {:event_move_result, {:ok, uid: uid, integration_id: new_integration_id}})
      else
        {:error, reason} ->
          send(lv_pid, {:event_move_result, {:error, original_event: event, reason: reason}})
      end
    end)

    socket
  end

  @spec update_attendees_async(Phoenix.LiveView.Socket.t(), map(), [map()]) ::
          Phoenix.LiveView.Socket.t()
  def update_attendees_async(socket, event, attendees) do
    user_id = socket.assigns.current_user.id
    lv_pid = self()

    event_data = %{
      summary: event.summary || "",
      start_time: event.start_at,
      end_time: event.end_at,
      description: event.description || "",
      location: event.location || "",
      provider_event_id: event.provider_event_id,
      attendees: attendees
    }

    timing =
      if event.all_day do
        %{start_date: event.start_date, end_date: event.end_date}
      else
        %{start_at: event.start_at, end_at: event.end_at}
      end

    cache_row =
      Map.merge(timing, %{
        uid: event.uid,
        calendar_integration_id: event.calendar_integration_id,
        provider: event.provider,
        provider_calendar_id: event.provider_calendar_id,
        provider_event_id: event.provider_event_id,
        summary: event.summary,
        all_day: event.all_day,
        location: event.location,
        description: event.description,
        attendees: attendees,
        status: event.status,
        provider_metadata: event.provider_metadata,
        synced_at: DateTime.utc_now(:second)
      })

    Task.Supervisor.start_child(Tymeslot.TaskSupervisor, fn ->
      result =
        EventOperations.update_event(
          event.uid,
          event_data,
          {event.calendar_integration_id, user_id}
        )

      case result do
        :ok ->
          CalendarGrid.update_cached_event(cache_row)
          send(lv_pid, {:event_update_result, :ok})

        {:error, reason} ->
          send(
            lv_pid,
            {:event_update_result, {:error, original_event: event, reason: reason}}
          )
      end
    end)

    socket
  end

  defp build_field_event_data(event, field, new_value) do
    base = %{
      summary: event.summary || "",
      start_time: event.start_at,
      end_time: event.end_at,
      description: event.description || "",
      location: event.location || "",
      provider_event_id: event.provider_event_id
    }

    case field do
      :summary -> %{base | summary: new_value}
      :location -> %{base | location: new_value}
      :description -> %{base | description: new_value}
    end
  end

  defp build_field_cache_row(event, field, new_value) do
    timing =
      if event.all_day do
        %{start_date: event.start_date, end_date: event.end_date}
      else
        %{start_at: event.start_at, end_at: event.end_at}
      end

    base =
      Map.merge(timing, %{
        uid: event.uid,
        calendar_integration_id: event.calendar_integration_id,
        provider: event.provider,
        provider_calendar_id: event.provider_calendar_id,
        provider_event_id: event.provider_event_id,
        summary: event.summary,
        all_day: event.all_day,
        location: event.location,
        description: event.description,
        attendees: event.attendees || [],
        status: event.status,
        provider_metadata: event.provider_metadata,
        synced_at: DateTime.utc_now(:second)
      })

    Map.put(base, field, new_value)
  end

  @doc """
  Routes an event edit through `Tymeslot.Meetings.AttendeeNotifications`.

  Returns one of:

    * `{:ok, :no_changes}` — nothing notifiable changed, or the event has no
      attendees. Caller should flash "Changes saved."
    * `{:ok, :already_pending}` — changes were notifiable, but a Worker job is
      already queued inside the debounce window. This call re-confirmed into
      the existing job (replacing `scheduled_at`). Caller should flash
      "Changes saved. Attendees will be notified shortly."
    * `{:needs_confirmation, ChangeSummary.t}` — notifiable changes, nothing
      pending. Caller should stash the summary and show the confirmation modal.
  """
  @spec notify_event_updated(map(), map(), [map()]) ::
          {:ok, :no_changes}
          | {:ok, :already_pending}
          | {:needs_confirmation, ChangeSummary.t()}
  def notify_event_updated(original_event, updated_event, attendees) do
    case AttendeeNotifications.event_updated(original_event, updated_event, attendees) do
      {:ok, :no_changes} ->
        {:ok, :no_changes}

      {:needs_confirmation, summary} ->
        if AttendeeNotifications.pending?(updated_event.id) do
          {:ok, :sent} =
            AttendeeNotifications.event_updated_confirm(updated_event, summary, attendees)

          {:ok, :already_pending}
        else
          {:needs_confirmation, summary}
        end
    end
  end

  @doc """
  Asynchronously synchronises the video integration selection for an event.

  Compares the `:video_integration_id` on `updated_event` against
  `original_event`. When unchanged, returns the socket immediately with no
  side effects. When changed, spawns a supervised task that provisions a
  meeting room via `Tymeslot.Integrations.Video.Rooms.create_meeting_room/2`
  (or clears the link when the new ID is `nil`), persists the result to the
  cached event row, then sends `{:video_sync_result, event_id, result}` to
  the LiveView process, where `result` is `{:ok, url_or_nil}` or
  `{:error, reason}`.

  Returns the (unchanged) socket immediately so callers are never blocked by
  the network round-trip to the video provider.
  """
  @spec sync_video_integration_async(
          Phoenix.LiveView.Socket.t(),
          map(),
          map()
        ) :: Phoenix.LiveView.Socket.t()
  def sync_video_integration_async(socket, original_event, updated_event) do
    old_id = Map.get(original_event, :video_integration_id)
    new_id = Map.get(updated_event, :video_integration_id)

    if old_id == new_id do
      socket
    else
      user_id = socket.assigns.current_user.id
      event_id = Map.get(updated_event, :id)
      lv_pid = self()

      Task.Supervisor.start_child(Tymeslot.TaskSupervisor, fn ->
        result = provision_video_link(updated_event, new_id, user_id)
        send(lv_pid, {:video_sync_result, event_id, result})
      end)

      socket
    end
  end

  defp provision_video_link(event, nil, _user_id) do
    persist_video_link(event, nil)
    {:ok, nil}
  end

  defp provision_video_link(event, integration_id, user_id) do
    case video_rooms_module().create_meeting_room(user_id, integration_id: integration_id) do
      {:ok, %{room_data: room_data}} ->
        url = room_data[:meeting_url] || room_data[:join_url]
        persist_video_link(event, url)
        {:ok, url}

      {:error, reason} = error ->
        Logger.warning("Failed to provision video room for event edit",
          user_id: user_id,
          event_id: Map.get(event, :id),
          video_integration_id: integration_id,
          reason: inspect(reason)
        )

        error
    end
  end

  defp persist_video_link(event, url) do
    timing =
      if event.all_day do
        %{start_date: event.start_date, end_date: event.end_date}
      else
        %{start_at: event.start_at, end_at: event.end_at}
      end

    CalendarGrid.update_cached_event(
      Map.merge(timing, %{
        uid: event.uid,
        calendar_integration_id: event.calendar_integration_id,
        provider: event.provider,
        provider_calendar_id: event.provider_calendar_id,
        provider_event_id: event.provider_event_id,
        summary: event.summary,
        all_day: event.all_day,
        location: event.location,
        description: event.description,
        attendees: event.attendees || [],
        status: event.status,
        provider_metadata: event.provider_metadata,
        video_link: url,
        synced_at: DateTime.utc_now(:microsecond)
      })
    )
  end

  defp video_rooms_module do
    Application.get_env(:tymeslot, :video_rooms_module, VideoRooms)
  end
end
