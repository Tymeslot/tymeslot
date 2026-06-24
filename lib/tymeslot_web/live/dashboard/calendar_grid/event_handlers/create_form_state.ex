defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.CreateFormState do
  @moduledoc "Event creation form-field handlers for the calendar grid (presentation layer)."

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Security.UniversalSanitizer
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared

  @spec handle_show_create_form(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_show_create_form(%{"start-hour" => _start_hour} = params, socket) do
    with {:ok, start_hour} <- Shared.parse_int(params["start-hour"]),
         {:ok, start_minute} <- Shared.parse_int(params["start-minute"]),
         {:ok, end_hour} <- Shared.parse_int(params["end-hour"]),
         {:ok, end_minute} <- Shared.parse_int(params["end-minute"]) do
      end_date = params["end-date"] || params["date"]

      creating =
        base_creating(socket, %{
          date: params["date"],
          end_date: end_date,
          start_hour: start_hour,
          start_minute: start_minute,
          end_hour: end_hour,
          end_minute: end_minute
        })

      {:noreply, assign(socket, :creating_event, creating)}
    else
      :error -> {:noreply, socket}
    end
  end

  # No time params (e.g. the `c` keyboard shortcut): open the create modal at the
  # next whole hour from "now" in the user's timezone, for a one-hour slot.
  def handle_show_create_form(_params, socket) do
    now = DateTime.shift_zone!(DateTime.utc_now(), socket.assigns.user_timezone)
    start_hour = if now.minute == 0, do: now.hour, else: rem(now.hour + 1, 24)
    today = Date.to_iso8601(DateTime.to_date(now))

    creating =
      base_creating(socket, %{
        date: today,
        end_date: today,
        start_hour: start_hour,
        start_minute: 0,
        end_hour: rem(start_hour + 1, 24),
        end_minute: 0
      })

    {:noreply, assign(socket, :creating_event, creating)}
  end

  # Builds a `creating_event` map, filling defaults for any field the caller omits.
  defp base_creating(socket, overrides) do
    default_int_id = EditWorkflow.default_integration_id(socket)
    today = Date.to_iso8601(Date.utc_today())

    defaults = %{
      date: today,
      end_date: today,
      start_hour: 9,
      start_minute: 0,
      end_hour: 10,
      end_minute: 0,
      all_day: false,
      title: "",
      integration_id: default_int_id,
      calendar_id: EditWorkflow.default_calendar_id(socket.assigns.integrations, default_int_id),
      attendees: [],
      attendee_input: "",
      reminders: [],
      recurrence_rule: nil,
      video_integration_id: nil
    }

    Map.merge(defaults, overrides)
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

  @spec handle_toggle_create_all_day(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_toggle_create_all_day(_params, socket) do
    case socket.assigns.creating_event do
      nil ->
        {:noreply, socket}

      creating ->
        updated = Map.put(creating, :all_day, not Map.get(creating, :all_day, false))
        {:noreply, assign(socket, :creating_event, updated)}
    end
  end

  @spec handle_add_create_reminder(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_add_create_reminder(params, socket) do
    case socket.assigns.creating_event do
      nil ->
        {:noreply, socket}

      creating ->
        case Shared.parse_reminder(params) do
          {:ok, reminder} ->
            existing = Map.get(creating, :reminders, [])
            new_reminders = Shared.add_reminder(existing, reminder)
            updated = Map.put(creating, :reminders, new_reminders)
            {:noreply, assign(socket, :creating_event, updated)}

          :error ->
            {:noreply, socket}
        end
    end
  end

  @spec handle_remove_create_reminder(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_remove_create_reminder(params, socket) do
    case socket.assigns.creating_event do
      nil ->
        {:noreply, socket}

      creating ->
        case Shared.parse_int(params["index"]) do
          {:ok, index} ->
            reminders = creating |> Map.get(:reminders, []) |> List.delete_at(index)
            {:noreply, assign(socket, :creating_event, Map.put(creating, :reminders, reminders))}

          :error ->
            {:noreply, socket}
        end
    end
  end

  @spec handle_update_create_recurrence(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_create_recurrence(params, socket) do
    case socket.assigns.creating_event do
      nil ->
        {:noreply, socket}

      creating ->
        rule = Shared.compose_recurrence_rule(params)
        {:noreply, assign(socket, :creating_event, Map.put(creating, :recurrence_rule, rule))}
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
      updated =
        Map.put(
          creating,
          :video_integration_id,
          Shared.parse_optional_int(params["video_integration_id"])
        )

      {:noreply, assign(socket, :creating_event, updated)}
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
end
