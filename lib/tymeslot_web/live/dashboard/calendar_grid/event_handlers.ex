defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers do
  @moduledoc "Event handler implementations for CalendarGridComponent. Each function takes event params and a socket, returning {:noreply, socket}."

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, send_update: 2]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.Operations, as: EventOperations
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Security.UniversalSanitizer
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers

  @spec handle_show_event(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_show_event(%{"event-id" => id_str}, socket) do
    case parse_int(id_str) do
      {:ok, event_id} ->
        event = Enum.find(socket.assigns.events, &(&1.id == event_id))
        {:noreply, assign(socket, :selected_event, event)}

      :error ->
        {:noreply, socket}
    end
  end

  @spec handle_close_event_detail(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_close_event_detail(_params, socket) do
    {:noreply, assign(socket, :selected_event, nil)}
  end

  @spec handle_update_event_title(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_event_title(%{"value" => new_title}, socket) do
    case socket.assigns.selected_event do
      nil ->
        {:noreply, socket}

      event ->
        with {:ok, sanitised} <-
               UniversalSanitizer.sanitize_and_validate(new_title, max_length: 500),
             trimmed = String.trim(sanitised),
             false <- trimmed == (event.title || ""),
             :ok <- EditWorkflow.assert_owns_event(socket, event),
             :ok <- check_edit_rate_limit(socket) do
          updated_event = %{event | title: trimmed}

          updated_events =
            Enum.map(socket.assigns.events, fn e ->
              if e.id == event.id, do: updated_event, else: e
            end)

          socket =
            socket
            |> assign(:selected_event, updated_event)
            |> assign(:events, updated_events)
            |> Helpers.precompute_derived()

          {:noreply, EditWorkflow.update_field_async(socket, event, :title, trimmed)}
        else
          true ->
            {:noreply, socket}

          {:error, :unauthorized} ->
            send(self(), {:flash, {:error, "You don't have permission to modify this event"}})
            {:noreply, socket}

          {:error, :rate_limited, _message} ->
            send(self(), {:flash, {:warning, "Too many edits. Please wait a moment."}})
            {:noreply, socket}

          {:error, reason} when is_binary(reason) ->
            send(self(), {:flash, {:error, "Input too long"}})
            {:noreply, socket}
        end
    end
  end

  @spec handle_update_event_location(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_event_location(%{"value" => new_location}, socket) do
    case socket.assigns.selected_event do
      nil ->
        {:noreply, socket}

      event ->
        with {:ok, sanitised} <-
               UniversalSanitizer.sanitize_and_validate(new_location, max_length: 1000),
             trimmed = String.trim(sanitised),
             false <- trimmed == (event.location || ""),
             :ok <- EditWorkflow.assert_owns_event(socket, event),
             :ok <- check_edit_rate_limit(socket) do
          updated_event = %{event | location: trimmed}

          updated_events =
            Enum.map(socket.assigns.events, fn e ->
              if e.id == event.id, do: updated_event, else: e
            end)

          socket =
            socket
            |> assign(:selected_event, updated_event)
            |> assign(:events, updated_events)
            |> Helpers.precompute_derived()

          {:noreply, EditWorkflow.update_field_async(socket, event, :location, trimmed)}
        else
          true ->
            {:noreply, socket}

          {:error, :unauthorized} ->
            send(self(), {:flash, {:error, "You don't have permission to modify this event"}})
            {:noreply, socket}

          {:error, :rate_limited, _message} ->
            send(self(), {:flash, {:warning, "Too many edits. Please wait a moment."}})
            {:noreply, socket}

          {:error, reason} when is_binary(reason) ->
            send(self(), {:flash, {:error, "Input too long"}})
            {:noreply, socket}
        end
    end
  end

  @spec handle_update_event_description(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_event_description(%{"value" => new_description}, socket) do
    case socket.assigns.selected_event do
      nil ->
        {:noreply, socket}

      event ->
        with {:ok, sanitised} <-
               UniversalSanitizer.sanitize_and_validate(new_description, max_length: 5000),
             trimmed = String.trim(sanitised),
             false <- trimmed == (event.description || ""),
             :ok <- EditWorkflow.assert_owns_event(socket, event),
             :ok <- check_edit_rate_limit(socket) do
          updated_event = %{event | description: trimmed}

          updated_events =
            Enum.map(socket.assigns.events, fn e ->
              if e.id == event.id, do: updated_event, else: e
            end)

          socket =
            socket
            |> assign(:selected_event, updated_event)
            |> assign(:events, updated_events)
            |> Helpers.precompute_derived()

          {:noreply, EditWorkflow.update_field_async(socket, event, :description, trimmed)}
        else
          true ->
            {:noreply, socket}

          {:error, :unauthorized} ->
            send(self(), {:flash, {:error, "You don't have permission to modify this event"}})
            {:noreply, socket}

          {:error, :rate_limited, _message} ->
            send(self(), {:flash, {:warning, "Too many edits. Please wait a moment."}})
            {:noreply, socket}

          {:error, reason} when is_binary(reason) ->
            send(self(), {:flash, {:error, "Input too long"}})
            {:noreply, socket}
        end
    end
  end

  @spec handle_update_event_calendar(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_event_calendar(params, socket) do
    id_str = params["integration-id"] || params["integration_id"]
    cal_id = params["calendar-id"]

    case {socket.assigns.selected_event, parse_int(id_str)} do
      {nil, _} ->
        {:noreply, socket}

      {event, {:ok, new_id}} when new_id == event.calendar_integration_id and is_nil(cal_id) ->
        {:noreply, socket}

      {event, {:ok, new_id}} ->
        with :ok <- EditWorkflow.assert_owns_event(socket, event),
             :ok <- check_move_rate_limit(socket) do
          updated_event = %{event | calendar_integration_id: new_id}

          updated_events =
            Enum.map(socket.assigns.events, fn e ->
              if e.id == event.id, do: updated_event, else: e
            end)

          socket =
            socket
            |> assign(:selected_event, updated_event)
            |> assign(:events, updated_events)
            |> Helpers.precompute_derived()
            |> EditWorkflow.move_event_async(event, new_id, calendar_id: cal_id)

          {:noreply, socket}
        else
          {:error, :unauthorized} ->
            send(self(), {:flash, {:error, "You don't have permission to move this event"}})
            {:noreply, socket}

          {:error, :rate_limited, _message} ->
            send(self(), {:flash, {:warning, "Too many moves. Please wait a moment."}})
            {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @spec handle_update_event_time(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_event_time(params, socket) do
    case socket.assigns.selected_event do
      nil ->
        {:noreply, socket}

      event ->
        tz = socket.assigns.user_timezone

        with {:ok, start_date} <- Date.from_iso8601(params["start-date"]),
             {:ok, start_time} <- Time.from_iso8601(params["start-time"] <> ":00"),
             {:ok, end_date} <- Date.from_iso8601(params["end-date"]),
             {:ok, end_time} <- Time.from_iso8601(params["end-time"] <> ":00"),
             :ok <- EditWorkflow.assert_owns_event(socket, event),
             :ok <- check_edit_rate_limit(socket) do
          new_start = to_utc(start_date, start_time.hour, start_time.minute, tz)
          raw_end = to_utc(end_date, end_time.hour, end_time.minute, tz)
          apply_time_change(socket, event, new_start, raw_end)
        else
          {:error, :unauthorized} ->
            send(self(), {:flash, {:error, "You don't have permission to modify this event"}})
            {:noreply, socket}

          {:error, :rate_limited, _message} ->
            send(self(), {:flash, {:warning, "Too many edits. Please wait a moment."}})
            {:noreply, socket}

          _error ->
            {:noreply, socket}
        end
    end
  end

  defp apply_time_change(socket, event, new_start, raw_end) do
    original_duration = DateTime.diff(event.end_at, event.start_at, :second)

    new_end =
      if DateTime.compare(raw_end, new_start) != :gt do
        DateTime.add(new_start, max(original_duration, 900), :second)
      else
        raw_end
      end

    if DateTime.compare(new_start, event.start_at) == :eq and
         DateTime.compare(new_end, event.end_at) == :eq do
      {:noreply, socket}
    else
      optimistic_event = %{event | start_at: new_start, end_at: new_end}
      socket = assign(socket, :selected_event, optimistic_event)

      {:noreply,
       EditWorkflow.apply_event_change(socket, event, optimistic_event, new_start, new_end)}
    end
  end

  @spec handle_prev_period(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_prev_period(_params, socket), do: navigate_period(socket, -1)

  @spec handle_next_period(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_next_period(_params, socket), do: navigate_period(socket, 1)

  defp navigate_period(socket, direction) do
    new_date =
      case socket.assigns.view do
        :month -> Helpers.navigate_month(socket.assigns.date, direction)
        :week -> Date.add(socket.assigns.date, 7 * direction)
        :day -> Date.add(socket.assigns.date, direction)
      end

    socket = socket |> assign(:date, new_date) |> Helpers.load_events()
    {:noreply, socket}
  end

  @spec handle_today(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_today(_params, socket) do
    socket =
      socket
      |> assign(:date, Date.utc_today())
      |> Helpers.load_events()

    {:noreply, socket}
  end

  @spec handle_set_view(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_set_view(%{"view" => view}, socket) when view in ~w(day week month) do
    view_atom = String.to_existing_atom(view)
    user_id = socket.assigns.current_user.id
    CalendarGrid.save_preferences(user_id, %{default_view: view})

    socket =
      socket
      |> assign(:view, view_atom)
      |> assign(:show_view_menu, false)
      |> Helpers.load_events()

    {:noreply, socket}
  end

  def handle_set_view(_params, socket), do: {:noreply, socket}

  @spec handle_navigate_to_day(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_navigate_to_day(%{"date" => date_str}, socket) do
    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        socket = socket |> assign(:view, :day) |> assign(:date, date) |> Helpers.load_events()
        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  @spec handle_toggle_calendar_list(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_toggle_calendar_list(_params, socket) do
    {:noreply,
     socket
     |> assign(:show_calendar_list, !socket.assigns.show_calendar_list)
     |> assign(:show_view_menu, false)}
  end

  @spec handle_toggle_view_menu(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_toggle_view_menu(_params, socket) do
    {:noreply,
     socket
     |> assign(:show_view_menu, !socket.assigns.show_view_menu)
     |> assign(:show_calendar_list, false)}
  end

  @spec handle_toggle_integration_visibility(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_toggle_integration_visibility(%{"integration-id" => id_str}, socket) do
    case parse_int(id_str) do
      {:ok, integration_id} -> handle_toggle_integration(socket, integration_id)
      :error -> {:noreply, socket}
    end
  end

  defp handle_toggle_integration(socket, integration_id) do
    user_id = socket.assigns.current_user.id
    current_hidden = socket.assigns.hidden_integration_ids

    new_hidden =
      if integration_id in current_hidden do
        List.delete(current_hidden, integration_id)
      else
        [integration_id | current_hidden]
      end

    CalendarGrid.save_preferences(user_id, %{
      hidden_integration_ids: new_hidden
    })

    socket =
      socket
      |> assign(:hidden_integration_ids, new_hidden)
      |> Helpers.precompute_derived()

    {:noreply, socket}
  end

  @spec handle_refresh(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_refresh(_params, socket) do
    user_id = socket.assigns.current_user.id

    case RateLimiter.check_calendar_refresh_rate_limit(user_id) do
      :ok ->
        {:noreply, do_refresh(socket, user_id)}

      {:error, :rate_limited, _message} ->
        {:noreply, put_flash(socket, :warning, "Too many refreshes. Please wait a moment.")}
    end
  end

  defp do_refresh(socket, user_id) do
    {:ok, result} = CalendarGrid.refresh_events(user_id)
    socket = Helpers.load_events(socket)

    cond do
      result.errors != [] ->
        put_flash(
          socket,
          :warning,
          "Refresh failed for #{length(result.errors)} integration(s)"
        )

      result.enqueued == 0 and result.skipped == 0 ->
        put_flash(socket, :info, "No calendars to sync")

      result.enqueued == 0 ->
        put_flash(socket, :info, "Calendars refreshed")

      true ->
        # Schedule fallback reset in case workers complete without broadcasting
        Process.send_after(self(), :reset_calendar_sync, 30_000)

        socket
        |> assign(:syncing, true)
        |> assign(:sync_total, result.enqueued + result.skipped)
        |> assign(:sync_completed, result.skipped)
    end
  end

  @spec handle_event_dropped(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event_dropped(params, socket) do
    EditWorkflow.with_editable_event(socket, params, fn event ->
      tz = socket.assigns.user_timezone

      with {:ok, new_date} <- Date.from_iso8601(params["new-date"]),
           {:ok, new_hour} <- parse_int(params["new-hour"]),
           {:ok, new_minute} <- parse_int(params["new-minute"]),
           {:ok, raw_end_hour} <- parse_int(params["new-end-hour"]),
           {:ok, new_end_minute} <- parse_int(params["new-end-minute"]) do
        new_end_hour = min(23, raw_end_hour)
        new_start = to_utc(new_date, new_hour, new_minute, tz)
        new_end = to_utc(new_date, new_end_hour, new_end_minute, tz)

        optimistic_event = %{event | start_at: new_start, end_at: new_end}
        EditWorkflow.apply_event_change(socket, event, optimistic_event, new_start, new_end)
      else
        :error -> {:noreply, socket}
        {:error, _reason} -> {:noreply, socket}
      end
    end)
  end

  @spec handle_event_resized(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event_resized(params, socket) do
    EditWorkflow.with_editable_event(socket, params, fn event ->
      tz = socket.assigns.user_timezone

      with {:ok, event_date} <- Date.from_iso8601(params["event-date"]),
           {:ok, raw_end_hour} <- parse_int(params["new-end-hour"]),
           {:ok, new_end_minute} <- parse_int(params["new-end-minute"]) do
        new_end_hour = min(23, raw_end_hour)
        new_end = to_utc(event_date, new_end_hour, new_end_minute, tz)

        optimistic_event = %{event | end_at: new_end}
        EditWorkflow.apply_event_change(socket, event, optimistic_event, event.start_at, new_end)
      else
        :error -> {:noreply, socket}
        {:error, _reason} -> {:noreply, socket}
      end
    end)
  end

  @spec handle_show_create_form(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_show_create_form(params, socket) do
    with {:ok, start_hour} <- parse_int(params["start-hour"]),
         {:ok, start_minute} <- parse_int(params["start-minute"]),
         {:ok, end_hour} <- parse_int(params["end-hour"]),
         {:ok, end_minute} <- parse_int(params["end-minute"]) do
      default_int_id = EditWorkflow.default_integration_id(socket)

      creating = %{
        date: params["date"],
        start_hour: start_hour,
        start_minute: start_minute,
        end_hour: end_hour,
        end_minute: end_minute,
        title: "",
        integration_id: default_int_id,
        calendar_id: EditWorkflow.default_calendar_id(socket.assigns.integrations, default_int_id)
      }

      {:noreply, assign(socket, :creating_event, creating)}
    else
      :error -> {:noreply, socket}
    end
  end

  @spec handle_close_create_form(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_close_create_form(_params, socket) do
    {:noreply, assign(socket, :creating_event, nil)}
  end

  @spec handle_update_create_title(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_create_title(%{"value" => title}, socket) do
    creating = Map.put(socket.assigns.creating_event, :title, title)
    {:noreply, assign(socket, :creating_event, creating)}
  end

  @spec handle_update_create_time(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_create_time(params, socket) do
    creating = socket.assigns.creating_event

    creating =
      creating
      |> maybe_update_date(params["date"])
      |> maybe_update_time(params["start-time"], :start_hour, :start_minute)
      |> maybe_update_time(params["end-time"], :end_hour, :end_minute)

    {:noreply, assign(socket, :creating_event, creating)}
  end

  @spec handle_update_create_integration(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_create_integration(params, socket) do
    id_str = params["integration-id"] || params["integration_id"]
    cal_id = params["calendar-id"]

    case parse_int(id_str) do
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

  @spec handle_save_event(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_save_event(_params, socket) do
    creating = socket.assigns.creating_event
    integration = Enum.find(socket.assigns.integrations, &(&1.id == creating.integration_id))

    if is_nil(integration) do
      send(self(), {:flash, {:error, "Invalid calendar selected"}})
      {:noreply, socket}
    else
      tz = socket.assigns.user_timezone

      case Date.from_iso8601(creating.date) do
        {:ok, date} ->
          send(
            self(),
            {:execute_create_event,
             %{
               creating: creating,
               user_id: socket.assigns.current_user.id,
               start_at: to_utc(date, creating.start_hour, creating.start_minute, tz),
               end_at: to_utc(date, creating.end_hour, creating.end_minute, tz)
             }}
          )

          {:noreply, assign(socket, :saving_event, true)}

        {:error, _reason} ->
          send(self(), {:flash, {:error, "Invalid date"}})
          {:noreply, socket}
      end
    end
  end

  @doc false
  @spec execute_create_event(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def execute_create_event(payload, socket) do
    %{creating: creating, user_id: user_id, start_at: start_at, end_at: end_at} = payload

    result =
      EventOperations.create_event(
        %{
          summary: creating.title,
          start_time: start_at,
          end_time: end_at,
          all_day: false,
          calendar_integration_id: creating.integration_id,
          calendar_id: creating[:calendar_id]
        },
        {creating.integration_id, user_id}
      )

    case result do
      {:ok, created} ->
        uid = if is_binary(created), do: created, else: created[:uid] || created["uid"]

        CalendarGrid.cache_created_event(%{
          uid: uid,
          calendar_integration_id: creating.integration_id,
          title: creating.title,
          start_at: start_at,
          end_at: end_at,
          all_day: false
        })

        send_update(TymeslotWeb.Dashboard.CalendarGridComponent,
          id: "calendar",
          action: :event_created
        )

        {:noreply, socket}

      {:error, _reason} ->
        send_update(TymeslotWeb.Dashboard.CalendarGridComponent,
          id: "calendar",
          action: :event_create_failed
        )

        {:noreply, put_flash(socket, :error, "Failed to create event")}
    end
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
            socket =
              socket
              |> assign(:selected_event, nil)
              |> assign(:confirm_delete_event, event)

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
        case check_edit_rate_limit(socket) do
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
  @spec execute_delete_event(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def execute_delete_event(payload, socket) do
    %{uid: uid, calendar_integration_id: integration_id, user_id: user_id} = payload

    opts =
      if payload[:provider_event_id], do: [provider_event_id: payload.provider_event_id], else: []

    case EventOperations.delete_event(uid, {integration_id, user_id}, opts) do
      :ok ->
        CalendarGrid.delete_cached_event(integration_id, uid)

        send_update(TymeslotWeb.Dashboard.CalendarGridComponent,
          id: "calendar",
          action: :event_deleted
        )

        {:noreply, socket}

      {:error, _reason} ->
        send_update(TymeslotWeb.Dashboard.CalendarGridComponent,
          id: "calendar",
          action: :event_delete_failed
        )

        {:noreply, put_flash(socket, :error, "Failed to delete event")}
    end
  end

  @spec handle_cancel_delete_event(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_cancel_delete_event(_params, socket) do
    {:noreply, assign(socket, :confirm_delete_event, nil)}
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

  @spec handle_toggle_settings(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_toggle_settings(_params, socket) do
    {:noreply,
     socket
     |> assign(:show_settings, !socket.assigns.show_settings)
     |> assign(:show_calendar_list, false)
     |> assign(:show_view_menu, false)}
  end

  @spec handle_close_settings(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_close_settings(_params, socket) do
    {:noreply, assign(socket, :show_settings, false)}
  end

  @spec handle_update_preference(map(), Phoenix.LiveView.Socket.t(), atom()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_preference(%{"option" => value}, socket, key) do
    user_id = socket.assigns.current_user.id
    CalendarGrid.save_preferences(user_id, %{key => value})

    prefs = %{socket.assigns.preferences | key => value}

    socket =
      socket
      |> assign(:preferences, prefs)
      |> Helpers.precompute_derived()

    {:noreply, socket}
  end

  @spec handle_update_default_view(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_default_view(%{"option" => value}, socket)
      when value in ~w(day week month) do
    user_id = socket.assigns.current_user.id
    view_atom = String.to_existing_atom(value)
    CalendarGrid.save_preferences(user_id, %{default_view: value})

    prefs = %{socket.assigns.preferences | default_view: value}

    # Instant grid switch (no DB query, no flicker)
    socket =
      socket
      |> assign(:preferences, prefs)
      |> assign(:view, view_atom)
      |> Helpers.precompute_derived()

    # Deferred event reload for the new view's date range
    Phoenix.LiveView.send_update_after(
      TymeslotWeb.Dashboard.CalendarGridComponent,
      %{id: "calendar", action: :reload_events},
      50
    )

    {:noreply, socket}
  end

  @spec handle_toggle_preference(map(), Phoenix.LiveView.Socket.t(), atom()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_toggle_preference(_params, socket, key) do
    user_id = socket.assigns.current_user.id
    new_value = !Map.get(socket.assigns.preferences, key)

    CalendarGrid.save_preferences(user_id, %{key => new_value})

    prefs = %{socket.assigns.preferences | key => new_value}

    socket =
      socket
      |> assign(:preferences, prefs)
      |> Helpers.precompute_derived()

    {:noreply, socket}
  end

  @spec handle_set_mobile_view(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_set_mobile_view(_params, socket) do
    if socket.assigns.view == :week do
      socket = socket |> assign(:view, :day) |> Helpers.load_events()
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @spec handle_navigate_swipe(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_navigate_swipe(%{"direction" => direction}, socket) do
    new_date =
      case direction do
        "next" -> Date.add(socket.assigns.date, 1)
        "prev" -> Date.add(socket.assigns.date, -1)
        _other -> socket.assigns.date
      end

    socket = socket |> assign(:date, new_date) |> Helpers.load_events()
    {:noreply, socket}
  end

  defp check_edit_rate_limit(socket) do
    user_id = socket.assigns.current_user.id

    case RateLimiter.check_calendar_event_edit_rate_limit(user_id) do
      :ok -> :ok
      {:error, :rate_limited, message} -> {:error, :rate_limited, message}
    end
  end

  defp check_move_rate_limit(socket) do
    user_id = socket.assigns.current_user.id

    case RateLimiter.check_calendar_event_move_rate_limit(user_id) do
      :ok -> :ok
      {:error, :rate_limited, message} -> {:error, :rate_limited, message}
    end
  end

  # Constructs a UTC DateTime from a date and time in the user's display timezone.
  # The calendar grid renders events in the user's timezone, so drag/drop/create
  # coordinates are in that timezone and must be converted back to UTC for storage.
  defp to_utc(date, hour, minute, timezone) do
    local_dt = DateTime.new!(date, Time.new!(hour, minute, 0), timezone)
    DateTime.shift_zone!(local_dt, "Etc/UTC")
  end

  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {value, ""} -> {:ok, value}
      _other -> :error
    end
  end

  defp parse_int(_not_binary), do: :error

  defp maybe_update_date(creating, date_str) when is_binary(date_str) and date_str != "" do
    case Date.from_iso8601(date_str) do
      {:ok, _date} -> Map.put(creating, :date, date_str)
      {:error, _} -> creating
    end
  end

  defp maybe_update_date(creating, _date_str), do: creating

  defp maybe_update_time(creating, time_str, hour_key, minute_key)
       when is_binary(time_str) and time_str != "" do
    case String.split(time_str, ":") do
      [h, m | _] ->
        with {hour, ""} <- Integer.parse(h),
             {minute, ""} <- Integer.parse(m) do
          creating
          |> Map.put(hour_key, hour)
          |> Map.put(minute_key, minute)
        else
          _ -> creating
        end

      _ ->
        creating
    end
  end

  defp maybe_update_time(creating, _time_str, _hour_key, _minute_key), do: creating
end
