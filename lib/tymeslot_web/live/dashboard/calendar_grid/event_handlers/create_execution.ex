defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.CreateExecution do
  @moduledoc "Event creation save/result handlers for the calendar grid (presentation layer)."

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, send_update: 2]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.EventCreation
  alias Tymeslot.Integrations.Calendar.Recurrence.RRule
  alias Tymeslot.Validation.AddressList
  alias Tymeslot.Venues
  alias TymeslotWeb.Components.Shared.ReminderPickerState
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.CreateFormState
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.GroupEventCreation
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared
  alias TymeslotWeb.Dashboard.CalendarGrid.WriteOutcomeMessages
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

  # Group-event mode creates a one-off event people sign up for; see
  # `GroupEventCreation`.
  defp handle_save_event_with(%{mode: :group_event} = creating, socket),
    do: GroupEventCreation.save(creating, socket)

  # Meeting mode books an ad-hoc Tymeslot meeting instead of writing a bare
  # provider event. A calendar integration is optional here: the booking is
  # native, and the provider copy is written back only when one is connected.
  #
  # Every save emails the main guest and any extra guests, so it is rate
  # limited like inviting guests to an existing booking. The check comes last
  # so that a form still being corrected does not spend the budget.
  defp handle_save_event_with(%{mode: :meeting} = creating, socket) do
    organizer_email = socket.assigns.current_user.email

    with {:ok, creating} <- commit_pending_reminder(creating),
         :ok <- authorize_optional_integration(socket, creating[:integration_id]),
         {:ok, start_at, end_at} <- resolve_timed_range(creating, socket),
         :ok <- validate_meeting_fields(creating, organizer_email),
         {:ok, guest_emails} <- extra_guest_emails(creating, organizer_email),
         :ok <- require_guests(creating, guest_emails),
         :ok <- Shared.check_quick_add_meeting_rate_limit(socket) do
      params =
        creating
        |> ad_hoc_params(socket, start_at, end_at)
        |> Map.put(:guest_emails, guest_emails)
        |> Map.put(:guest_names, guest_names(creating))

      send(self(), {:execute_create_ad_hoc_meeting, params})

      {:noreply, socket |> assign(:creating_event, creating) |> assign(:saving_event, true)}
    else
      error -> meeting_save_failed(error, socket)
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
        with {:ok, creating} <- put_event_location(creating, socket),
             {:ok, start_date} <- Date.from_iso8601(creating.date),
             {:ok, end_date} <- Date.from_iso8601(creating.end_date) do
          save_with_fitted_recurrence(creating, start_date, end_date, socket)
        else
          {:error, :invalid_location} ->
            send(self(), {:flash, {:error, invalid_location_message()}})
            {:noreply, socket}

          {:error, _reason} ->
            send(
              self(),
              {:flash, {:error, dgettext("dashboard_calendar_events", "Invalid date")}}
            )

            {:noreply, socket}
        end
    end
  end

  # A plain event's location is the text its calendar entry carries
  # (`creating.location`, which `EventCreation` writes to the provider): a
  # saved venue's one-line form (`Venues.display/1`), or what was typed in.
  # The venue is read afresh among the host's own rather than from the list
  # the grid loaded, so one deleted while the form was open is refused
  # rather than written as a stale name.
  defp put_event_location(creating, socket) do
    case location_of(creating) do
      nil ->
        {:ok, Map.put(creating, :location, nil)}

      {:custom, place} ->
        {:ok, Map.put(creating, :location, place)}

      {:venue, venue_id} ->
        case Venues.get_venue(socket.assigns.current_user.id, venue_id) do
          {:ok, venue} -> {:ok, Map.put(creating, :location, Venues.display(venue))}
          {:error, :not_found} -> {:error, :invalid_location}
        end
    end
  end

  # The location chosen in `LocationFields`, as `Bookings.CreateAdHoc` takes
  # it, or nil for none. A custom place left blank is none.
  defp location_of(creating) do
    case creating[:location_choice] do
      "venue:" <> id ->
        case Integer.parse(id) do
          {venue_id, ""} -> {:venue, venue_id}
          _malformed -> nil
        end

      "custom" ->
        case String.trim(creating[:location_custom] || "") do
          "" -> nil
          place -> {:custom, place}
        end

      _none ->
        nil
    end
  end

  defp invalid_location_message,
    do: WriteOutcomeMessages.ad_hoc_failed_message(:invalid_location)

  # Why a meeting-mode save stopped short. A rejected reminder is already
  # worded inside the picker, so it needs no flash of its own.
  defp meeting_save_failed({:error, :reminder_rejected, creating}, socket),
    do: {:noreply, assign(socket, :creating_event, creating)}

  defp meeting_save_failed({:error, message}, socket) when is_binary(message) do
    send(self(), {:flash, {:error, message}})
    {:noreply, socket}
  end

  defp meeting_save_failed({:error, :rate_limited, _message}, socket) do
    send(
      self(),
      {:flash,
       {:warning,
        dgettext(
          "dashboard_calendar_events",
          "Too many new meetings. Please wait a moment."
        )}}
    )

    {:noreply, socket}
  end

  defp meeting_save_failed({:error, :unauthorized}, socket) do
    send(
      self(),
      {:flash, {:error, dgettext("dashboard_calendar_events", "Invalid calendar selected")}}
    )

    {:noreply, socket}
  end

  # The recurrence editor composes the rule as the form changes, so it can
  # predate the final all-day flag and start date. Fit it to the event being
  # saved: a date-only UNTIL for an all-day event, and no series that ends
  # before it starts. A timed event's UNTIL is an instant, so it ends its day
  # in the organiser's timezone rather than in UTC.
  #
  # A calendar the grid writes no repeat rule to (Exchange) is given none:
  # its editor is hidden, but a rule picked for another calendar first stays.
  defp save_with_fitted_recurrence(creating, start_date, end_date, socket) do
    rule = if repeatable_destination?(creating, socket), do: Map.get(creating, :recurrence_rule)

    case RRule.retarget(rule,
           all_day: Map.get(creating, :all_day, false),
           start_date: start_date,
           timezone: socket.assigns.user_timezone
         ) do
      {:ok, rule} ->
        creating
        |> Map.put(:recurrence_rule, rule)
        |> save_resolved(start_date, end_date, socket)

      {:error, :until_before_start} = error ->
        Shared.flash_guard_error(socket, error)
    end
  end

  # Builds the payload the async ad-hoc booking path consumes.
  #
  # Without a main participant the meeting is the host's to manage, and every
  # address is a guest's: the booking path picks the one that fills the
  # attendee fields (`EventCreation.run_create_ad_hoc_meeting/1`), so none is
  # passed from here. Its title is required (`validate_meeting_fields/2`).
  defp ad_hoc_params(%{main_participant: false} = creating, socket, start_at, end_at) do
    creating
    |> common_ad_hoc_params(socket, start_at, end_at)
    |> Map.merge(%{title: String.trim(creating.title), managed_by_host: true})
  end

  # An untitled meeting with a main participant falls back to naming them,
  # which is what the organiser will recognise it by on the grid.
  defp ad_hoc_params(creating, socket, start_at, end_at) do
    guest_name = String.trim(creating.guest_name)

    title =
      case String.trim(creating.title || "") do
        "" -> dgettext("dashboard_calendar_events", "Meeting with %{name}", name: guest_name)
        custom -> custom
      end

    creating
    |> common_ad_hoc_params(socket, start_at, end_at)
    |> Map.merge(%{
      title: title,
      attendee_name: guest_name,
      attendee_email: String.trim(creating.guest_email)
    })
  end

  defp common_ad_hoc_params(creating, socket, start_at, end_at) do
    %{
      start_time: start_at,
      end_time: end_at,
      attendee_timezone: socket.assigns.user_timezone,
      organizer_user_id: socket.assigns.current_user.id,
      calendar_integration_id: creating[:integration_id],
      calendar_id: creating[:calendar_id],
      video_integration_id: creating[:video_integration_id],
      organizer_note: creating[:organizer_note],
      attendee_locale: creating[:locale],
      reminders: reminders_of(creating),
      location: location_of(creating)
    }
  end

  # Create feels like it submits everything in the modal, so a custom reminder
  # typed but never added goes in with it. One that fails validation keeps the
  # modal open with the picker's own message rather than creating the meeting
  # as if nothing had been typed.
  defp commit_pending_reminder(%{meeting_reminders: %{} = state} = creating) do
    if ReminderPickerState.pending?(state) do
      case ReminderPickerState.add_custom(state) do
        {:ok, added} ->
          {:ok, Map.put(creating, :meeting_reminders, added)}

        {:noop, rejected} ->
          {:error, :reminder_rejected, Map.put(creating, :meeting_reminders, rejected)}
      end
    else
      {:ok, creating}
    end
  end

  defp commit_pending_reminder(creating), do: {:ok, creating}

  # What the reminder picker holds, or nothing at all. Nothing is an answer
  # here: a quick-added meeting sends the reminders the host picked and no
  # others, so an untouched picker means no reminder email.
  defp reminders_of(creating) do
    case creating[:meeting_reminders] do
      %{reminders: reminders} -> reminders
      _unset -> []
    end
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
      dispatch_create(socket, creating, true, start_date, Date.add(end_date, 1))
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
        dispatch_create(socket, creating, false, start_at, end_at)
      end
    else
      {:error, _reason} ->
        send(self(), {:flash, {:error, dgettext("dashboard_calendar_events", "Invalid time")}})
        {:noreply, socket}
    end
  end

  # A provider event can carry attendees the provider invites by email, and
  # every create is a provider write, so it spends the same budget as an edit.
  # The check sits here, after validation, so a form still being corrected
  # does not spend it.
  defp dispatch_create(socket, creating, all_day, start_at, end_at) do
    case Shared.check_edit_rate_limit(socket) do
      :ok ->
        send(
          self(),
          {:execute_create_event,
           %{
             creating: creating,
             user_id: socket.assigns.current_user.id,
             all_day: all_day,
             start_at: start_at,
             end_at: end_at,
             timezone: socket.assigns.user_timezone
           }}
        )

        {:noreply, assign(socket, :saving_event, true)}

      {:error, :rate_limited, _message} = error ->
        Shared.flash_guard_error(socket, error)
    end
  end

  @doc false
  @spec handle_create_result({:ok, map()} | {:error, term()}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_create_result({:ok, result}, socket) do
    %{
      uid: uid,
      creating: creating,
      start_at: start_at,
      end_at: end_at,
      provider: provider,
      provider_event_id: provider_event_id,
      written_calendar_id: written_calendar_id,
      etag: etag,
      default_booking_calendar_id: default_booking_calendar_id,
      attendees: attendees,
      meeting_url: meeting_url,
      description: description
    } = result

    # What the provider actually wrote, before what was asked for. A CalDAV
    # write falls back to the booking collection when the chosen calendar is
    # not one the integration lists as writable, and filing the row under the
    # request instead showed the event on a calendar it is not on until the
    # next sync corrected it, with every edit addressed by that row aimed at
    # the wrong collection in the meantime.
    provider_calendar_id =
      written_calendar_id || creating[:calendar_id] || default_booking_calendar_id || "primary"

    all_day = Map.get(creating, :all_day, false)

    timing = cache_timing(all_day, start_at, end_at)

    CalendarGrid.cache_created_event(
      Map.merge(timing, %{
        uid: uid,
        calendar_integration_id: creating.integration_id,
        provider: provider,
        provider_calendar_id: provider_calendar_id,
        # What the provider said about the event it just wrote. Without these
        # the row carried no identity until a full sync repaired it: every
        # conditional update spent a HEAD probe first and then fell back to the
        # weaker `If-Match: *`, and a write could only be addressed by
        # rebuilding the URL from whichever calendar the client is scoped to.
        # Either may be nil (a CalDAV server is not obliged to answer a PUT
        # with an ETag), and a nil leaves the column as it was.
        provider_event_id: provider_event_id,
        etag: etag,
        summary: creating.title,
        description: description,
        location: creating[:location],
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

  def handle_create_result({:error, failure}, socket) do
    send_update(CalendarGridComponent,
      id: "calendar",
      action: :event_create_failed
    )

    {:noreply, put_flash(socket, :error, create_failed_message(failure))}
  end

  # A queued create will be replayed on the next sync; anything else is final.
  defp create_failed_message(%{retry: :queued}),
    do: dgettext("dashboard_calendar_events", "Create failed - queued to retry on next sync")

  defp create_failed_message(%{reason: :rule_not_supported_by_outlook}),
    do: EditWorkflow.rule_not_supported_by_outlook_message()

  defp create_failed_message(%{reason: :day_missing_in_some_months}),
    do: EditWorkflow.month_end_refused_message()

  defp create_failed_message(_failure),
    do: dgettext("dashboard_calendar_events", "Failed to create event")

  # An ad-hoc meeting may be created with no integration at all; when one is
  # selected it must be the user's own.
  defp authorize_optional_integration(_socket, nil), do: :ok

  defp authorize_optional_integration(socket, integration_id),
    do: EditWorkflow.assert_owns_integration(socket, integration_id)

  defp repeatable_destination?(creating, socket) do
    case Enum.find(socket.assigns[:integrations] || [], &(&1.id == creating[:integration_id])) do
      nil -> true
      integration -> CalendarGrid.repeatable_provider?(integration.provider)
    end
  end

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

  # Without a main participant the guests are checked as they are added
  # (`CreateFormState.check_extra_guest/3`), so only the title is left: there
  # is no guest whose name could stand in for it.
  defp validate_meeting_fields(%{main_participant: false} = creating, _organizer_email) do
    if String.trim(creating.title || "") == "",
      do:
        {:error,
         dgettext(
           "dashboard_calendar_events",
           "Add a title. A meeting without a main participant is known by its title."
         )},
      else: :ok
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

      CreateFormState.same_address?(guest_email, organizer_email) ->
        {:error,
         dgettext(
           "dashboard_calendar_events",
           "You cannot add yourself as a guest. Use a different email address."
         )}

      true ->
        :ok
    end
  end

  # An address typed into the extra-guest field but never added is still one
  # the host means to invite, so it is taken along rather than lost. An
  # invalid one, or the host's own, stops the save; a repeat or the main
  # guest's own address is settled by `EventCreation` like any other.
  defp extra_guest_emails(creating, organizer_email) do
    added = creating[:guest_emails] || []
    %{email: pending} = pending_guest(creating)

    cond do
      pending == "" ->
        {:ok, added}

      Shared.valid_email?(pending) and not CreateFormState.same_address?(pending, organizer_email) ->
        {:ok, added ++ [pending]}

      true ->
        CreateFormState.check_extra_guest(creating, pending, organizer_email)
    end
  end

  # The names typed with the extra guests, the one still in the input
  # among them.
  defp guest_names(creating) do
    creating
    |> CreateFormState.put_guest_name(pending_guest(creating))
    |> Map.get(:guest_names, %{})
  end

  defp pending_guest(creating), do: AddressList.parse_entry(creating[:guest_email_input] || "")

  # A meeting without a main participant is for its guests, so it needs one.
  defp require_guests(%{main_participant: false}, []),
    do: {:error, dgettext("dashboard_calendar_events", "Invite at least one guest.")}

  defp require_guests(_creating, _guest_emails), do: :ok

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
