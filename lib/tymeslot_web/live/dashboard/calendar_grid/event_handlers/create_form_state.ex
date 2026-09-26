defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.CreateFormState do
  @moduledoc "Event creation form-field handlers for the calendar grid (presentation layer)."

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Clock
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Locales
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Security.UniversalSanitizer
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers

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
    now = DateTime.shift_zone!(Clock.utc_now(), socket.assigns.user_timezone)

    creating = base_creating(socket, default_slot(now))

    {:noreply, assign(socket, :creating_event, creating)}
  end

  # The next whole hour, for an hour. Both ends carry their own date, so a slot
  # that runs into midnight simply ends on the following one. Deriving the end
  # by adding an hour to the start, rather than to the start's hour number, is
  # what keeps it on the right date and on the right side of a DST transition.
  defp default_slot(now) do
    start_at = next_whole_hour(now)
    end_at = default_end(start_at)

    %{
      date: iso_date(start_at),
      end_date: iso_date(end_at),
      start_hour: start_at.hour,
      start_minute: 0,
      end_hour: end_at.hour,
      end_minute: 0
    }
  end

  # An hour after the start, expressed as a wall-clock hour the form can hold.
  # On the autumn DST night the wall clock repeats, so 02:00 CEST plus an hour
  # is 02:00 CET and the end hour would equal the start hour, proposing a slot
  # of no length that the save then refuses. Step to the next distinct hour
  # there. The repeated hour remains valid as input, since a user really can
  # book across it; it is only the default that must not land on it.
  defp default_end(start_at) do
    end_at = DateTime.add(start_at, 1, :hour)

    if end_at.hour == start_at.hour, do: DateTime.add(end_at, 1, :hour), else: end_at
  end

  defp next_whole_hour(%DateTime{minute: 0} = now), do: now

  defp next_whole_hour(%DateTime{minute: minute} = now),
    do: DateTime.add(now, 60 - minute, :minute)

  defp iso_date(at), do: at |> DateTime.to_date() |> Date.to_iso8601()

  defp writable?(socket) do
    Calendar.writable_integrations(socket.assigns.integrations) != []
  end

  # Builds a `creating_event` map, filling defaults for any field the caller omits.
  defp base_creating(socket, overrides) do
    default_int_id = EditWorkflow.default_integration_id(socket)
    today = Date.to_iso8601(Helpers.today(socket.assigns.user_timezone))

    defaults = %{
      date: today,
      end_date: today,
      start_hour: 9,
      start_minute: 0,
      end_hour: 10,
      end_minute: 0,
      all_day: false,
      title: "",
      # With no calendar that can be written to there is nothing a provider
      # event could go into, so the form opens straight in meeting mode. A
      # subscription counts as no calendar here: it can be read and never
      # written.
      mode: if(writable?(socket), do: :event, else: :meeting),
      guest_name: "",
      guest_email: "",
      guest_emails: [],
      guest_email_input: "",
      message: "",
      # Which language the guest is written to. Defaults to the host's own —
      # they know whom they are inviting — and is theirs to change per meeting.
      locale: Locales.guest_default_locale(Map.get(socket.assigns, :current_user)),
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

  @spec handle_set_create_mode(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_set_create_mode(%{"mode" => mode}, socket) do
    creating = socket.assigns.creating_event

    cond do
      is_nil(creating) or mode not in ~w(event meeting) ->
        {:noreply, socket}

      # Event mode needs a calendar that can be written to.
      mode == "event" and not writable?(socket) ->
        {:noreply, socket}

      true ->
        updated =
          case mode do
            # Meetings are always timed; clear a stray all-day toggle so the
            # time inputs reappear.
            "meeting" -> creating |> Map.put(:mode, :meeting) |> Map.put(:all_day, false)
            "event" -> Map.put(creating, :mode, :event)
          end

        {:noreply, assign(socket, :creating_event, updated)}
    end
  end

  @spec handle_update_create_guest_name(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_create_guest_name(%{"value" => name}, socket) do
    case socket.assigns.creating_event do
      nil ->
        {:noreply, socket}

      creating ->
        case UniversalSanitizer.sanitize_and_validate(name, mode: :plain_text, max_length: 200) do
          {:ok, sanitised} ->
            {:noreply, assign(socket, :creating_event, Map.put(creating, :guest_name, sanitised))}

          {:error, _reason} ->
            {:noreply, socket}
        end
    end
  end

  @spec handle_update_create_guest_email(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_create_guest_email(%{"value" => email}, socket) do
    case socket.assigns.creating_event do
      nil ->
        {:noreply, socket}

      creating ->
        trimmed = email |> String.trim() |> String.slice(0, 320)
        {:noreply, assign(socket, :creating_event, Map.put(creating, :guest_email, trimmed))}
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

  @spec handle_toggle_create_all_day(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_toggle_create_all_day(_params, socket) do
    case socket.assigns.creating_event do
      nil ->
        {:noreply, socket}

      creating ->
        {:noreply, assign(socket, :creating_event, toggle_all_day(creating))}
    end
  end

  # Switching All-day on collapses the range to the start's day. The timed
  # default gives both ends their own date, so a slot opened late in the
  # evening already ends tomorrow; carried into an all-day event that reads as
  # a deliberate two-day banner, which is never what ticking the box meant.
  # The reverse direction is left alone: a user who widened an all-day event
  # across several days and then unticks the box has said what they want.
  defp toggle_all_day(%{all_day: true} = creating), do: %{creating | all_day: false}

  defp toggle_all_day(%{date: date} = creating),
    do: %{creating | all_day: true, end_date: date}

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
        # The event's all-day flag and start date can still change before the
        # form is saved, so only the timezone is fixed enough to compose with;
        # `CreateExecution` refits the rest to the event that is saved.
        rule =
          Shared.compose_recurrence_rule(params, %{timezone: socket.assigns.user_timezone})

        {:noreply, assign(socket, :creating_event, Map.put(creating, :recurrence_rule, rule))}
    end
  end

  @spec handle_update_create_integration(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_create_integration(params, socket) do
    case socket.assigns.creating_event do
      nil ->
        {:noreply, socket}

      creating_event ->
        id_str = params["integration-id"] || params["integration_id"]
        cal_id = params["calendar-id"]

        case Shared.parse_int(id_str) do
          {:ok, id} ->
            creating =
              creating_event
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

  @doc """
  Adds one more guest to an ad-hoc meeting.

  Capped at `Guests.max_guests/0`, the same number a booker may bring, and the
  cap the domain enforces again when the meeting is created. The main guest's
  own address is refused here rather than silently dropped later, so the host
  can see why nothing happened.
  """
  @spec handle_add_create_guest(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_add_create_guest(%{"email" => raw_email}, socket) do
    creating = socket.assigns.creating_event

    if is_nil(creating) do
      {:noreply, socket}
    else
      email = raw_email |> String.trim() |> String.downcase()

      if addable_guest?(creating, email) do
        updated =
          creating
          |> Map.put(:guest_emails, creating.guest_emails ++ [email])
          |> Map.put(:guest_email_input, "")

        {:noreply, assign(socket, :creating_event, updated)}
      else
        {:noreply, socket}
      end
    end
  end

  @spec handle_remove_create_guest(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_remove_create_guest(%{"email" => email}, socket) do
    creating = socket.assigns.creating_event

    if is_nil(creating) do
      {:noreply, socket}
    else
      updated = Map.put(creating, :guest_emails, List.delete(creating.guest_emails, email))
      {:noreply, assign(socket, :creating_event, updated)}
    end
  end

  @spec handle_update_create_guest_input(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_create_guest_input(%{"email" => value}, socket) do
    put_field(socket, :guest_email_input, value)
  end

  @spec handle_update_create_message(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_create_message(%{"value" => message}, socket) do
    case UniversalSanitizer.sanitize_and_validate(message, mode: :plain_text, max_length: 2000) do
      {:ok, clean} -> put_field(socket, :message, clean)
      {:error, _reason} -> {:noreply, socket}
    end
  end

  @spec handle_update_create_locale(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_create_locale(%{"locale" => locale}, socket) do
    case Locales.acceptable(locale) do
      nil -> {:noreply, socket}
      code -> put_field(socket, :locale, code)
    end
  end

  defp addable_guest?(creating, email) do
    Shared.valid_email?(email) and
      email not in creating.guest_emails and
      email != String.downcase(String.trim(creating.guest_email || "")) and
      length(creating.guest_emails) < Guests.max_guests()
  end

  defp put_field(socket, key, value) do
    case socket.assigns.creating_event do
      nil -> {:noreply, socket}
      creating -> {:noreply, assign(socket, :creating_event, Map.put(creating, key, value))}
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
