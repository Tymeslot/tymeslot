defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.InlineEdit do
  @moduledoc "Inline edit event handlers for CalendarGridComponent."

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Meetings.AttendeeNotifications
  alias Tymeslot.Security.UniversalSanitizer
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow.Moves
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow.Updates
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow.VideoSync
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers

  @spec handle_show_event(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_show_event(%{"event-id" => id_str}, socket) do
    case Shared.parse_int(id_str) do
      {:ok, event_id} ->
        event = Enum.find(socket.assigns.events, &(&1.id == event_id))
        pending? = event != nil and AttendeeNotifications.pending?(event.id)

        {:noreply,
         socket
         |> assign(:selected_event, event)
         |> assign(:pending_attendees, [])
         |> assign(:attendee_input, "")
         |> assign(:pending_notification, pending?)}

      :error ->
        {:noreply, socket}
    end
  end

  @spec handle_close_event_detail(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_close_event_detail(_params, socket) do
    sub_modal_open =
      socket.assigns.confirm_remove_attendee != nil or
        socket.assigns.confirm_discard_attendees

    cond do
      sub_modal_open ->
        {:noreply, socket}

      socket.assigns.pending_attendees != [] ->
        {:noreply, assign(socket, :confirm_discard_attendees, true)}

      true ->
        {:noreply,
         socket
         |> assign(:selected_event, nil)
         |> assign(:attendee_input, "")}
    end
  end

  @spec handle_update_event_title(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_event_title(%{"value" => new_value}, socket),
    do: handle_update_event_field(:summary, 500, new_value, socket)

  @spec handle_update_edit_video(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_edit_video(params, socket) do
    case socket.assigns.selected_event do
      nil ->
        {:noreply, socket}

      event ->
        new_id = Shared.parse_optional_int(params["video_integration_id"])
        updated_event = Map.put(event, :video_integration_id, new_id)
        {:noreply, assign(socket, :selected_event, updated_event)}
    end
  end

  @spec handle_update_event_location(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_event_location(%{"value" => new_value}, socket),
    do: handle_update_event_field(:location, 1000, new_value, socket)

  @spec handle_update_event_description(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_event_description(%{"value" => new_value}, socket),
    do: handle_update_event_field(:description, 5000, new_value, socket)

  @spec handle_update_event_time(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_event_time(params, socket) do
    case socket.assigns.selected_event do
      nil ->
        {:noreply, socket}

      event ->
        tz = socket.assigns.user_timezone

        with {:ok, {start_date, start_time, end_date, end_time}} <- parse_time_inputs(params),
             :ok <- EditWorkflow.assert_owns_event(socket, event),
             :ok <- Shared.check_edit_rate_limit(socket),
             {:ok, new_start} <- Shared.to_utc(start_date, start_time.hour, start_time.minute, tz),
             {:ok, raw_end} <- Shared.to_utc(end_date, end_time.hour, end_time.minute, tz) do
          apply_time_change(socket, event, new_start, raw_end)
        else
          {:error, :unauthorized} = error -> Shared.flash_guard_error(socket, error)
          {:error, :rate_limited, _message} = error -> Shared.flash_guard_error(socket, error)
          _error -> {:noreply, socket}
        end
    end
  end

  # Parses the four raw date/time form fields into a tuple, short-circuiting on
  # the first malformed value. Keeps the caller's `with` chain flat.
  defp parse_time_inputs(params) do
    with {:ok, start_date} <- Date.from_iso8601(params["start-date"]),
         {:ok, start_time} <- Time.from_iso8601(normalize_time(params["start-time"])),
         {:ok, end_date} <- Date.from_iso8601(params["end-date"]),
         {:ok, end_time} <- Time.from_iso8601(normalize_time(params["end-time"])) do
      {:ok, {start_date, start_time, end_date, end_time}}
    end
  end

  @spec handle_toggle_event_all_day(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_toggle_event_all_day(_params, socket) do
    case socket.assigns.selected_event do
      nil ->
        {:noreply, socket}

      event ->
        with :ok <- EditWorkflow.assert_owns_event(socket, event),
             :ok <- Shared.check_edit_rate_limit(socket) do
          optimistic_event = toggle_all_day(event, socket.assigns.user_timezone)
          push_all_day_change(socket, event, optimistic_event)
        else
          {:error, :unauthorized} = error -> Shared.flash_guard_error(socket, error)
          {:error, :rate_limited, _message} = error -> Shared.flash_guard_error(socket, error)
        end
    end
  end

  @spec handle_update_event_all_day_range(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_event_all_day_range(params, socket) do
    case socket.assigns.selected_event do
      nil ->
        {:noreply, socket}

      %{all_day: true} = event ->
        with {:ok, start_date} <- Date.from_iso8601(params["start-date"]),
             {:ok, end_date} <- parse_end_date(params["end-date"], start_date),
             :ok <- EditWorkflow.assert_owns_event(socket, event),
             :ok <- Shared.check_edit_rate_limit(socket) do
          # The form presents inclusive dates; storage keeps `end_date`
          # exclusive, so a single-day range (start == end) is stored as +1.
          exclusive_end = Date.add(end_date, 1)

          if Date.compare(start_date, event.start_date) == :eq and
               Date.compare(exclusive_end, event.end_date) == :eq do
            {:noreply, socket}
          else
            optimistic_event = %{event | start_date: start_date, end_date: exclusive_end}
            push_all_day_change(socket, event, optimistic_event)
          end
        else
          {:error, :unauthorized} = error -> Shared.flash_guard_error(socket, error)
          {:error, :rate_limited, _message} = error -> Shared.flash_guard_error(socket, error)
          _error -> {:noreply, socket}
        end

      _timed ->
        {:noreply, socket}
    end
  end

  @spec handle_add_event_reminder(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_add_event_reminder(params, socket) do
    case socket.assigns.selected_event do
      nil ->
        {:noreply, socket}

      event ->
        with {:ok, reminder} <- Shared.parse_reminder(params),
             existing = event.reminders || [],
             new_reminders = Shared.add_reminder(existing, reminder),
             true <- new_reminders != existing,
             :ok <- EditWorkflow.assert_owns_event(socket, event),
             :ok <- Shared.check_edit_rate_limit(socket) do
          push_reminders_change(socket, event, new_reminders)
        else
          false ->
            {:noreply, socket}

          {:error, :unauthorized} = error ->
            Shared.flash_guard_error(socket, error)

          {:error, :rate_limited, _message} = error ->
            Shared.flash_guard_error(socket, error)

          :error ->
            {:noreply, socket}
        end
    end
  end

  @spec handle_remove_event_reminder(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_remove_event_reminder(params, socket) do
    case socket.assigns.selected_event do
      nil ->
        {:noreply, socket}

      event ->
        with {:ok, index} <- Shared.parse_int(params["index"]),
             :ok <- EditWorkflow.assert_owns_event(socket, event),
             :ok <- Shared.check_edit_rate_limit(socket) do
          new_reminders = List.delete_at(event.reminders || [], index)
          push_reminders_change(socket, event, new_reminders)
        else
          {:error, :unauthorized} = error -> Shared.flash_guard_error(socket, error)
          {:error, :rate_limited, _message} = error -> Shared.flash_guard_error(socket, error)
          :error -> {:noreply, socket}
        end
    end
  end

  @spec handle_update_event_recurrence(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_event_recurrence(params, socket) do
    case socket.assigns.selected_event do
      nil ->
        {:noreply, socket}

      event ->
        event_context = %{
          all_day: Map.get(event, :all_day, false),
          start_date: recurrence_start_date(event)
        }

        case Shared.compose_recurrence_rule(params, event_context) do
          {:error, :until_before_start} = error ->
            Shared.flash_guard_error(socket, error)

          new_rule ->
            if new_rule == event.recurrence_rule do
              {:noreply, socket}
            else
              with :ok <- EditWorkflow.assert_owns_event(socket, event),
                   :ok <- Shared.check_edit_rate_limit(socket) do
                push_recurrence_change(socket, event, new_rule)
              else
                {:error, :unauthorized} = error ->
                  Shared.flash_guard_error(socket, error)

                {:error, :rate_limited, _message} = error ->
                  Shared.flash_guard_error(socket, error)
              end
            end
        end
    end
  end

  # The selected event is a schema struct (no Access behaviour), so read its
  # fields with `Map.get/2` rather than bracket syntax. Falls back to the
  # timed start instant's date when the event has no all-day start_date.
  defp recurrence_start_date(event) do
    Map.get(event, :start_date) ||
      case Map.get(event, :start_at) do
        %DateTime{} = start_at -> DateTime.to_date(start_at)
        _other -> nil
      end
  end

  @spec handle_update_event_colour(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_event_colour(params, socket) do
    case socket.assigns.selected_event do
      nil ->
        {:noreply, socket}

      event ->
        new_colour = Shared.parse_colour(params["colour"])

        if new_colour == Map.get(event, :colour) do
          {:noreply, socket}
        else
          with :ok <- EditWorkflow.assert_owns_event(socket, event),
               :ok <- Shared.check_edit_rate_limit(socket) do
            push_colour_change(socket, event, new_colour)
          else
            {:error, :unauthorized} = error -> Shared.flash_guard_error(socket, error)
            {:error, :rate_limited, _message} = error -> Shared.flash_guard_error(socket, error)
          end
        end
    end
  end

  @spec handle_update_event_calendar(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_event_calendar(params, socket) do
    id_str = params["integration-id"] || params["integration_id"]
    cal_id = params["calendar-id"]

    case {socket.assigns.selected_event, Shared.parse_int(id_str)} do
      {nil, _parsed_id} ->
        {:noreply, socket}

      {event, {:ok, new_id}} when new_id == event.calendar_integration_id and is_nil(cal_id) ->
        {:noreply, socket}

      {event, {:ok, new_id}} ->
        with :ok <- EditWorkflow.assert_owns_event(socket, event),
             :ok <- EditWorkflow.assert_owns_integration(socket, new_id),
             :ok <- Shared.check_move_rate_limit(socket) do
          updated_event = %{event | calendar_integration_id: new_id}
          updated_events = Shared.replace_event(socket.assigns.events, event.id, updated_event)

          socket =
            socket
            |> assign(:selected_event, updated_event)
            |> assign(:events, updated_events)
            |> Helpers.precompute_derived()
            |> Moves.move_event_async(event, new_id, calendar_id: cal_id)

          {:noreply, socket}
        else
          {:error, :unauthorized} ->
            send(
              self(),
              {:flash,
               {:error,
                dgettext(
                  "dashboard_calendar_events",
                  "You don't have permission to move this event"
                )}}
            )

            {:noreply, socket}

          {:error, :rate_limited, _message} ->
            send(
              self(),
              {:flash,
               {:warning,
                dgettext("dashboard_calendar_events", "Too many moves. Please wait a moment.")}}
            )

            {:noreply, socket}
        end

      _unmatched ->
        {:noreply, socket}
    end
  end

  defp handle_update_event_field(field, max_length, new_value, socket) do
    case socket.assigns.selected_event do
      nil ->
        {:noreply, socket}

      event ->
        with {:ok, sanitised} <-
               UniversalSanitizer.sanitize_and_validate(new_value,
                 mode: :plain_text,
                 max_length: max_length
               ),
             trimmed = String.trim(sanitised),
             false <- trimmed == (Map.get(event, field) || ""),
             :ok <- EditWorkflow.assert_owns_event(socket, event),
             :ok <- Shared.check_edit_rate_limit(socket) do
          updated_event = Map.put(event, field, trimmed)
          updated_events = Shared.replace_event(socket.assigns.events, event.id, updated_event)

          socket =
            socket
            |> assign(:selected_event, updated_event)
            |> assign(:events, updated_events)
            |> Helpers.precompute_derived()
            |> Updates.update_field_async(event, field, trimmed)

          {:noreply, apply_notify_result(socket, event, updated_event)}
        else
          true ->
            {:noreply, socket}

          {:error, :unauthorized} = error ->
            Shared.flash_guard_error(socket, error)

          {:error, :rate_limited, _message} = error ->
            Shared.flash_guard_error(socket, error)

          {:error, reason} when is_binary(reason) ->
            message =
              if String.starts_with?(reason, "Input exceeds"),
                do: dgettext("dashboard_calendar_events", "Input too long"),
                else: dgettext("dashboard_calendar_events", "Input contains invalid characters")

            send(self(), {:flash, {:error, message}})
            {:noreply, socket}
        end
    end
  end

  defp normalize_time(t) when byte_size(t) == 5, do: t <> ":00"
  defp normalize_time(t), do: t

  # Converts a timed event to all-day (deriving the date range from the local
  # start/end) and vice versa (defaulting a single-day all-day event to a
  # 09:00–10:00 timed slot in the user's timezone).
  #
  # `end_date` is stored exclusively (matching the iCal/Google/Outlook all-day
  # convention and the grid's render filter), so a single-day all-day event has
  # `end_date == start_date + 1`. The conversions translate between that
  # exclusive boundary and the inclusive last day a timed event touches.
  defp toggle_all_day(%{all_day: true} = event, tz) do
    start_date = event.start_date
    # Exclusive end_date → inclusive last day the event covers.
    last_day = Date.add(event.end_date, -1)
    last_day = if Date.compare(last_day, start_date) == :lt, do: start_date, else: last_day

    # DST gap/ambiguous is extremely unlikely at 09:00/10:00, but we default
    # gracefully rather than crashing: on gap the shifted `just_after` is used,
    # and on ambiguous the DST-side is picked — both are acceptable defaults
    # when toggling the all-day flag programmatically.
    {:ok, start_at} = Shared.to_utc(start_date, 9, 0, tz)
    {:ok, end_at} = Shared.to_utc(last_day, 10, 0, tz)

    %{
      event
      | all_day: false,
        start_at: start_at,
        end_at: end_at,
        start_date: nil,
        end_date: nil
    }
  end

  defp toggle_all_day(event, tz) do
    start_date = event.start_at |> DateTime.shift_zone!(tz) |> DateTime.to_date()
    last_day = event.end_at |> DateTime.shift_zone!(tz) |> DateTime.to_date()
    # Inclusive last day → exclusive end_date.
    end_date = Date.add(last_day, 1)

    %{
      event
      | all_day: true,
        start_date: start_date,
        end_date: end_date,
        start_at: nil,
        end_at: nil
    }
  end

  defp push_colour_change(socket, original_event, new_colour) do
    optimistic_event = Map.put(original_event, :colour, new_colour)

    result =
      Shared.apply_optimistic_update(socket, optimistic_event, fn s ->
        Updates.update_colour_async(s, original_event, new_colour)
      end)

    send(self(), {:flash, {:info, dgettext("dashboard_calendar_events", "Changes saved.")}})
    result
  end

  defp push_reminders_change(socket, original_event, new_reminders) do
    optimistic_event = %{original_event | reminders: new_reminders}

    result =
      Shared.apply_optimistic_update(socket, optimistic_event, fn s ->
        Updates.update_reminders_async(s, original_event, new_reminders)
      end)

    send(self(), {:flash, {:info, dgettext("dashboard_calendar_events", "Changes saved.")}})
    result
  end

  # Applies a recurrence-rule change. When the event is already part of a
  # recurring series, the scope prompt (this / this-and-following / all events)
  # is shown first and the actual write is deferred to confirmation; otherwise
  # the rule is written straight away.
  #
  # Recurrence changes deviate from the standard `apply_optimistic_update`
  # pattern: the async step is conditional on whether the event belongs to a
  # series, so the update and the flash are handled inline here.
  defp push_recurrence_change(socket, original_event, new_rule) do
    optimistic_event = %{original_event | recurrence_rule: new_rule}

    updated_events =
      Shared.replace_event(socket.assigns.events, original_event.id, optimistic_event)

    socket =
      socket
      |> assign(:selected_event, optimistic_event)
      |> assign(:events, updated_events)
      |> Helpers.precompute_derived()

    if original_event.recurring_event_id do
      prompt = %{
        kind: :recurrence_rule,
        event: original_event,
        optimistic_event: optimistic_event,
        recurrence_rule: new_rule,
        original_event: original_event
      }

      {:noreply, assign(socket, :recurrence_prompt, prompt)}
    else
      socket = Updates.update_recurrence_async(socket, original_event, new_rule)
      send(self(), {:flash, {:info, dgettext("dashboard_calendar_events", "Changes saved.")}})
      {:noreply, socket}
    end
  end

  defp push_all_day_change(socket, original_event, optimistic_event) do
    result =
      Shared.apply_optimistic_update(socket, optimistic_event, fn s ->
        Updates.toggle_all_day_async(s, original_event, optimistic_event)
      end)

    send(self(), {:flash, {:info, dgettext("dashboard_calendar_events", "Changes saved.")}})
    result
  end

  defp parse_end_date(end_str, start_date) do
    case Date.from_iso8601(end_str) do
      {:ok, end_date} ->
        if Date.compare(end_date, start_date) == :lt do
          {:ok, start_date}
        else
          {:ok, end_date}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp apply_time_change(socket, event, _new_start, _raw_end) when event.all_day == true do
    send(
      self(),
      {:flash,
       {:info,
        dgettext("dashboard_calendar_events", "Time editing is not available for all-day events.")}}
    )

    {:noreply, socket}
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

      socket =
        socket
        |> assign(:selected_event, optimistic_event)
        |> EditWorkflow.apply_event_change(event, optimistic_event, new_start, new_end)

      {:noreply, apply_notify_result(socket, event, optimistic_event)}
    end
  end

  defp apply_notify_result(socket, original_event, updated_event) do
    socket = VideoSync.sync_video_integration_async(socket, original_event, updated_event)

    attendees = updated_event.attendees || original_event.attendees || []

    case EditWorkflow.notify_event_updated(original_event, updated_event, attendees) do
      {:ok, :no_changes} ->
        send(self(), {:flash, {:info, dgettext("dashboard_calendar_events", "Changes saved.")}})
        socket

      {:ok, :already_pending} ->
        send(
          self(),
          {:flash,
           {:info,
            dgettext(
              "dashboard_calendar_events",
              "Changes saved. Attendees will be notified shortly."
            )}}
        )

        assign(socket, :pending_notification, true)

      {:needs_confirmation, summary} ->
        assign(socket, :notify_prompt, %{
          kind: :update,
          summary: summary,
          event: updated_event,
          attendees: attendees
        })
    end
  end
end
