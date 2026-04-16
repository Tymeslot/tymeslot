defmodule Tymeslot.Meetings.AttendeeNotifications.Worker do
  @moduledoc """
  Runs at the end of the 2-minute debounce window. Re-reads the current event
  state, re-diffs it against `last_notified_state`, and either dispatches a
  single batched notification email reflecting the aggregated delta or no-ops
  if the effective diff is empty.

  On successful dispatch, the event's `last_notified_state` is updated to the
  current serialised snapshot and `ical_sequence` is bumped via
  `ChangeSummary.next_sequence`. The whole read/dispatch/persist path runs
  inside a `Repo.transaction/1` so a failing step rolls back and the next
  Oban retry sees the same starting state.
  """

  use Oban.Worker, queue: :emails, max_attempts: 5

  alias Tymeslot.Emails.EmailScheduler.CalendarScheduler
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Meetings.AttendeeNotifications.ChangeDetector
  alias Tymeslot.Meetings.AttendeeNotifications.ChangeSummary
  alias Tymeslot.Meetings.AttendeeNotifications.IcalMethod
  alias Tymeslot.Meetings.AttendeeNotifications.LastNotifiedState
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event_id" => id, "kind" => kind, "action" => action}}) do
    txn_result = Repo.transaction(fn -> do_run(id, kind, action) end)
    handle_result(txn_result, id, kind, action)
  end

  defp do_run(id, kind, action) do
    case run(id, kind, action) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp handle_result({:ok, _result}, _id, _kind, _action), do: :ok

  defp handle_result({:error, :not_found}, id, kind, action) do
    Logger.info("AttendeeNotifications.Worker skipped — event not found",
      event_id: id,
      kind: kind,
      action: action
    )

    :ok
  end

  defp handle_result({:error, reason}, id, kind, action) do
    Logger.error("AttendeeNotifications.Worker failed",
      event_id: id,
      kind: kind,
      action: action,
      reason: inspect(reason)
    )

    {:error, reason}
  end

  defp run(id, kind, action) do
    with {:ok, event} <- load_event(id, kind) do
      action_atom = String.to_existing_atom(action)
      current = current_event_map(event)
      baseline = LastNotifiedState.to_event(event.last_notified_state)
      summary = ChangeDetector.diff(baseline, current, current_sequence: event.ical_sequence)

      if ChangeSummary.any_changes?(summary) do
        :ok = dispatch(event, summary, action_atom)
        persist_new_baseline(event, current, summary.next_sequence)
      else
        log_noop(event, action_atom)
        :ok
      end
    end
  end

  defp load_event(id, "meeting"), do: MeetingQueries.get_meeting(id)

  defp load_event(id, "provider_calendar_event") when is_integer(id),
    do: ProviderCalendarEventQueries.fetch(id)

  defp load_event(id, "provider_calendar_event") when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> ProviderCalendarEventQueries.fetch(int_id)
      _other -> {:error, :not_found}
    end
  end

  defp load_event(_id, _kind), do: {:error, :not_found}

  # Normalises both single-attendee meetings and multi-attendee provider events
  # into the shape ChangeDetector expects: `:title`, `:starts_at`, `:ends_at`,
  # `:location`, `:description`, `:video_link`, and an `:attendees` list of
  # `%{email: ...}` maps.
  defp current_event_map(event) do
    %{
      title: Map.get(event, :summary) || Map.get(event, :title),
      starts_at: Map.get(event, :start_at) || Map.get(event, :start_time),
      ends_at: Map.get(event, :end_at) || Map.get(event, :end_time),
      location: Map.get(event, :location),
      description: Map.get(event, :description),
      video_link: Map.get(event, :video_link) || Map.get(event, :attendee_video_url),
      attendees: normalise_attendees(event)
    }
  end

  defp normalise_attendees(%{attendees: list}) when is_list(list) do
    Enum.map(list, &normalise_attendee/1)
  end

  defp normalise_attendees(%{attendee_email: email}) when is_binary(email) and email != "" do
    [%{email: email}]
  end

  defp normalise_attendees(_event), do: []

  defp normalise_attendee(%{email: email}) when is_binary(email), do: %{email: email}
  defp normalise_attendee(%{"email" => email}) when is_binary(email), do: %{email: email}
  defp normalise_attendee(other) when is_map(other), do: other

  defp dispatch(event, %ChangeSummary{} = summary, action_atom) do
    {method, sequence} =
      IcalMethod.for(ical_action(action_atom), current_sequence: event.ical_sequence)

    recipients = recipients_for(summary, action_atom)

    Enum.each(recipients, fn attendee ->
      CalendarScheduler.schedule_event_update_notification(%{
        user_id: user_id_for(event),
        event_uid: event.uid,
        integration_id: integration_id_for(event),
        attendee_emails: [Map.get(attendee, :email)],
        before_title: last_state_string(event, "title"),
        before_location: last_state_string(event, "location"),
        before_description: last_state_string(event, "description"),
        before_start_at: last_state_datetime(event, "starts_at"),
        before_end_at: last_state_datetime(event, "ends_at"),
        method: method,
        sequence: sequence
      })
    end)

    :ok
  end

  defp recipients_for(%ChangeSummary{retained_attendees: retained}, :update), do: retained

  defp recipients_for(
         %ChangeSummary{retained_attendees: retained, added_attendees: added},
         :delete
       ),
       do: retained ++ added

  defp ical_action(:update), do: :event_updated
  defp ical_action(:delete), do: :event_deleted

  defp user_id_for(%{organizer_user_id: id}) when is_integer(id), do: id
  defp user_id_for(%{calendar_integration: %{user_id: id}}) when is_integer(id), do: id
  defp user_id_for(_event), do: nil

  defp integration_id_for(%{calendar_integration_id: id}) when is_integer(id), do: id
  defp integration_id_for(_event), do: nil

  defp last_state_string(%{last_notified_state: state}, key) when is_map(state),
    do: Map.get(state, key)

  defp last_state_datetime(%{last_notified_state: state}, key) when is_map(state) do
    parse_iso_datetime(Map.get(state, key))
  end

  defp parse_iso_datetime(nil), do: nil

  defp parse_iso_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      _error -> nil
    end
  end

  defp persist_new_baseline(event, current, new_sequence) do
    new_state = LastNotifiedState.serialise(current, current.attendees)

    case update_baseline(event, new_state, new_sequence) do
      {:ok, _updated} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp update_baseline(%MeetingSchema{} = meeting, state, sequence),
    do: MeetingQueries.update_notification_baseline(meeting, state, sequence)

  defp update_baseline(%ProviderCalendarEventSchema{} = event, state, sequence),
    do: ProviderCalendarEventQueries.update_notification_baseline(event, state, sequence)

  defp log_noop(event, action_atom) do
    Logger.info("AttendeeNotifications.Worker no-op",
      event_id: event.id,
      action: action_atom,
      reason: "diff empty"
    )

    :ok
  end
end
