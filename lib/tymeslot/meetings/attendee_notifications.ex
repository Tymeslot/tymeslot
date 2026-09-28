defmodule Tymeslot.Meetings.AttendeeNotifications do
  @moduledoc """
  Single public entry point for every calendar-event attendee message.

  All call sites — dashboard create/edit flows, inline edits, booking
  cancellations, ad-hoc meetings — go through this module. It is the boundary
  between the rest of the codebase and the notification subsystem
  (`ChangeDetector`, `ChangeSummary`, `IcalMethod`, `Dispatcher`, `Worker`).

  ## Semantics

    * `event_created/2` — sends invitations immediately, one per attendee.
      Used for newly-created events that already have attendees attached.
    * `event_updated/3` — pure diff. Returns `{:ok, :no_changes}` when nothing
      notifiable has changed or the event has no attendees; otherwise returns
      `{:needs_confirmation, ChangeSummary.t}` so the caller can show a
      confirmation modal.
    * `event_updated_confirm/3` — called after the user confirms; delegates
      to the Dispatcher debounce window.
    * `series_updated_confirm/4` — the same, for an edit of this and every
      following occurrence of a series or of all of them, sent at once from
      the event as it was and as the edit left it, since such a write drops
      the cached rows the debounced job would read.
    * `attendees_added/2` / `attendees_removed/2` — immediate send path for
      membership-only changes (method `:request` or `:cancel` respectively).
    * `event_deleted/3` — returns `{:needs_confirmation, count}` so the caller
      knows to show a confirmation prompt; `{:ok, :no_attendees}` if there is
      nobody to notify, and `{:ok, :not_organiser}` for an event the user
      only attends, whose cancellation is not theirs to send.
    * `event_deleted_confirm/3` — sends the cancellation at once, one per
      attendee, from the event as it was, and only for an event the user
      organises. Called once the event has actually been deleted, never
      before: see its docs.
    * `pending?/1` / `cancel_pending/1` — inspection and cancellation of the
      debounced pipeline. Both take the event, not its id: `meetings` and
      `provider_calendar_events` number their rows independently, so an id
      alone does not name an event.

  The debounced update path is owned by `Dispatcher`. This module does
  not itself know anything about Oban.
  """

  alias Tymeslot.Emails.EmailScheduler.CalendarScheduler
  alias Tymeslot.Integrations.Calendar.Attendee
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Meetings.AttendeeNotifications.ChangeDetector
  alias Tymeslot.Meetings.AttendeeNotifications.ChangeSummary
  alias Tymeslot.Meetings.AttendeeNotifications.Dispatcher
  alias Tymeslot.Meetings.AttendeeNotifications.IcalMethod
  alias Tymeslot.Meetings.AttendeeNotifications.Recipients
  alias Tymeslot.Meetings.MeetingSchema

  @type event :: map
  @type attendee ::
          Attendee.t() | %{optional(:email) => String.t(), optional(:name) => String.t() | nil}

  @spec event_created(event, [attendee]) :: {:ok, :sent | :noop}
  def event_created(_event, []), do: {:ok, :noop}

  def event_created(event, attendees) when is_list(attendees) do
    {method, sequence} =
      IcalMethod.for(:event_created, current_sequence: current_sequence(event))

    send_immediate(event, attendees, method, sequence)
    {:ok, :sent}
  end

  @spec event_updated(event, event, [attendee]) ::
          {:ok, :no_changes} | {:needs_confirmation, ChangeSummary.t()}
  def event_updated(_old_event, _new_event, []), do: {:ok, :no_changes}

  def event_updated(old_event, new_event, attendees) when is_list(attendees) do
    old_map = to_event_map(old_event, attendees)
    new_map = to_event_map(new_event, attendees)

    summary =
      ChangeDetector.diff(old_map, new_map, current_sequence: current_sequence(new_event))

    if ChangeSummary.any_changes?(summary) do
      {:needs_confirmation, summary}
    else
      {:ok, :no_changes}
    end
  end

  @spec event_updated_confirm(event, ChangeSummary.t(), [attendee]) ::
          {:ok, :sent} | {:error, term}
  def event_updated_confirm(event, %ChangeSummary{} = _summary, _attendees) do
    case Dispatcher.schedule_update(event_id(event), event_kind(event)) do
      {:ok, :scheduled} -> {:ok, :sent}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Sends the update of an edit of this and every following occurrence of a
  recurring series, or of all of them (`scope` `:following` or `:all`), at
  once: one email job for every attendee, carrying the event as it was and
  as the edit left it.

  Not debounced like `event_updated_confirm/3`, whose job reads the event's
  cached row when it runs: a write to a whole series drops the series' rows
  until a sync brings them back (`Tymeslot.CalendarGrid.SeriesEdit`), so
  that job would find nothing and tell nobody. This one reads nothing back.

  Call it only once the calendar has accepted the write. `original_event` is
  the occurrence the organiser edited, as it was; `updated_event` is that
  occurrence as the write left it, whose attendees are the recipients, less
  anyone who declined and the user `owner_user_id`. `{:ok, :noop}` when
  nobody is left to tell.
  """
  @spec series_updated_confirm(event, event, pos_integer(), :following | :all) ::
          {:ok, :sent | :noop} | {:error, term}
  def series_updated_confirm(original_event, updated_event, owner_user_id, scope)
      when scope in [:following, :all] do
    excluded = Recipients.excluded(updated_event, owner_user_id)

    recipients =
      (Map.get(updated_event, :attendees) || [])
      |> Enum.map(&Recipients.email/1)
      |> Enum.reject(&(is_nil(&1) or &1 in excluded))
      |> Enum.uniq()

    notify_series_updated(original_event, updated_event, recipients, owner_user_id, scope)
  end

  defp notify_series_updated(_original, _updated, [], _owner_user_id, _scope), do: {:ok, :noop}

  defp notify_series_updated(original, updated, recipients, owner_user_id, scope) do
    {method, sequence} =
      IcalMethod.for(:event_updated, current_sequence: current_sequence(original))

    params = %{
      user_id: owner_user_id,
      event_uid: Map.get(updated, :uid),
      integration_id: Map.get(updated, :calendar_integration_id),
      attendee_emails: recipients,
      before_title: title_for(original),
      before_location: Map.get(original, :location),
      before_description: Map.get(original, :description),
      before_start_at: start_at_for(original),
      before_end_at: end_at_for(original),
      before_start_date: iso_date(Map.get(original, :start_date)),
      before_end_date: iso_date(Map.get(original, :end_date)),
      method: method,
      sequence: sequence,
      event: event_snapshot(updated),
      series: scope
    }

    case CalendarScheduler.schedule_event_update_notification(params) do
      :ok -> {:ok, :sent}
      {:error, reason} -> {:error, reason}
    end
  end

  # The event as the update email describes it, in the job's JSON args.
  defp event_snapshot(event) do
    %{
      "uid" => Map.get(event, :uid),
      "summary" => title_for(event),
      "location" => Map.get(event, :location),
      "description" => Map.get(event, :description),
      "all_day" => Map.get(event, :all_day) == true,
      "start_at" => iso(start_at_for(event)),
      "end_at" => iso(end_at_for(event)),
      "start_date" => iso_date(Map.get(event, :start_date)),
      "end_date" => iso_date(Map.get(event, :end_date))
    }
  end

  @spec attendees_added(event, [attendee]) :: {:ok, :sent | :noop}
  def attendees_added(_event, []), do: {:ok, :noop}

  def attendees_added(event, new_attendees) when is_list(new_attendees) do
    {method, sequence} =
      IcalMethod.for(:attendees_added, current_sequence: current_sequence(event))

    send_immediate(event, new_attendees, method, sequence)
    {:ok, :sent}
  end

  @spec attendees_removed(event, [attendee]) :: {:ok, :sent | :noop}
  def attendees_removed(_event, []), do: {:ok, :noop}

  def attendees_removed(event, removed_attendees) when is_list(removed_attendees) do
    {method, sequence} =
      IcalMethod.for(:attendees_removed, current_sequence: current_sequence(event))

    send_immediate(event, removed_attendees, method, sequence)
    {:ok, :sent}
  end

  @doc """
  Whether deleting `event` should ask the user `user_id` about telling its
  attendees: `{:needs_confirmation, count}` when it has attendees and the
  user organises it (`Recipients.organised_by?/2`).

  `{:ok, :not_organiser}` for an event someone else organises, which the
  user only attends: deleting it removes it from their calendar alone, and a
  cancellation in their name would tell the real organiser and every other
  guest that the event is off.
  """
  @spec event_deleted(event, [attendee], pos_integer()) ::
          {:ok, :no_attendees | :not_organiser} | {:needs_confirmation, non_neg_integer}
  def event_deleted(_event, [], _user_id), do: {:ok, :no_attendees}

  def event_deleted(event, attendees, user_id) when is_list(attendees) do
    if Recipients.organised_by?(event, user_id),
      do: {:needs_confirmation, length(attendees)},
      else: {:ok, :not_organiser}
  end

  @doc """
  Sends the cancellation of a deleted event to its attendees: one email per
  attendee, enqueued at once, each carrying everything it says about the
  event (title, timing, location, uid, sequence and whether the whole series
  went). Nothing is read back later, so it is sent whether or not the event's
  cached row still exists by then.

  Call it only once the calendar has deleted the event: a cancellation for
  an event still in the calendar is wrong, and one sent before a delete that
  then fails cannot be taken back.

  `event` is the cached row as it was before the delete, whose attendees are
  the recipients, less anyone who declined and the user `owner_user_id`
  (who made the delete). `scope` is `:series` when the whole series was
  deleted, which the email says; anything else cancels the one event.
  `{:ok, :noop}` when nobody is left to tell, and for an event someone else
  organises, whose cancellation is not the user's to send (see
  `event_deleted/3`).
  """
  @spec event_deleted_confirm(event, pos_integer(), :occurrence | :series) ::
          {:ok, :sent | :noop} | {:error, term}
  def event_deleted_confirm(event, owner_user_id, scope) do
    if Recipients.organised_by?(event, owner_user_id),
      do: cancel_for_attendees(event, owner_user_id, scope),
      else: {:ok, :noop}
  end

  defp cancel_for_attendees(event, owner_user_id, scope) do
    excluded = Recipients.excluded(event, owner_user_id)

    recipients =
      (Map.get(event, :attendees) || [])
      |> Enum.map(&Attendee.normalise/1)
      |> Enum.reject(fn attendee ->
        email = Recipients.email(attendee)
        is_nil(email) or email in excluded
      end)
      |> Enum.uniq_by(&Recipients.email/1)

    notify_deleted(event, recipients, owner_user_id, scope)
  end

  defp notify_deleted(_event, [], _owner_user_id, _scope), do: {:ok, :noop}

  defp notify_deleted(event, recipients, owner_user_id, scope) do
    {method, sequence} =
      IcalMethod.for(:event_deleted, current_sequence: current_sequence(event))

    extra = %{user_id: owner_user_id, series: scope == :series}

    case send_immediate(event, recipients, method, sequence, extra) do
      :ok -> {:ok, :sent}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Whether a debounced job is already queued for this event.

  Takes the event rather than its id so the kind is derived from the struct:
  ids are only unique *within* a kind, and an id that matched a job of the
  other kind used to answer `true` here. That sent the caller down the
  "already pending" branch, joining a stranger's debounce window instead of
  asking this event's host, off nothing but a numeric collision.
  """
  @spec pending?(event) :: boolean
  def pending?(event) do
    Dispatcher.pending?(event_id(event), event_kind(event))
  end

  @spec cancel_pending(event) :: :ok
  def cancel_pending(event) do
    Dispatcher.cancel_pending(event_id(event), event_kind(event))
  end

  ## Internal helpers

  # `extra` overrides the defaults: the organiser a caller already knows, and
  # whether a cancellation takes the whole series. Returns the first failure
  # to enqueue, after trying every attendee.
  defp send_immediate(event, attendees, method, sequence, extra \\ %{}) do
    timing = invitation_timing(event)

    attendees
    |> Enum.map(fn attendee ->
      CalendarScheduler.schedule_calendar_invitation(
        timing
        |> Map.merge(%{
          user_id: user_id_for(event),
          attendee_email: Map.get(attendee, :email),
          event_title: title_for(event),
          event_uid: Map.get(event, :uid),
          event_location: Map.get(event, :location),
          event_description: Map.get(event, :description),
          method: method,
          sequence: sequence
        })
        |> Map.merge(extra)
      )
    end)
    |> Enum.find(:ok, &match?({:error, _reason}, &1))
  end

  # An all-day event has dates and no instants, so it travels as dates; the
  # instants stay in the args as nil because the job requires the keys.
  defp invitation_timing(%{all_day: true, start_date: %Date{} = start_date, end_date: end_date}) do
    %{
      all_day: true,
      event_start_date: Date.to_iso8601(start_date),
      event_end_date: Date.to_iso8601(end_date),
      event_start_at: nil,
      event_end_at: nil
    }
  end

  defp invitation_timing(event) do
    %{event_start_at: iso(start_at_for(event)), event_end_at: iso(end_at_for(event))}
  end

  defp to_event_map(event, attendees) do
    %{
      title: title_for(event),
      starts_at: start_at_for(event),
      ends_at: end_at_for(event),
      start_date: Map.get(event, :start_date),
      end_date: Map.get(event, :end_date),
      location: Map.get(event, :location),
      description: Map.get(event, :description),
      video_link: video_link_for(event),
      attendees: attendees
    }
  end

  defp title_for(event), do: Map.get(event, :summary) || Map.get(event, :title)

  defp start_at_for(event),
    do: Map.get(event, :start_at) || Map.get(event, :start_time)

  defp end_at_for(event),
    do: Map.get(event, :end_at) || Map.get(event, :end_time)

  defp video_link_for(%ProviderCalendarEventSchema{video_link: url}), do: url

  defp video_link_for(event),
    do: Map.get(event, :video_link) || Map.get(event, :attendee_video_url)

  defp current_sequence(event), do: Map.get(event, :ical_sequence, 0) || 0

  defp event_id(%{id: id}) when is_integer(id), do: id

  defp event_kind(%MeetingSchema{}), do: :meeting
  defp event_kind(%ProviderCalendarEventSchema{}), do: :provider_calendar_event

  defp user_id_for(%{organizer_user_id: id}) when is_integer(id), do: id
  defp user_id_for(%{calendar_integration: %{user_id: id}}) when is_integer(id), do: id
  defp user_id_for(_event), do: nil

  defp iso_date(%Date{} = date), do: Date.to_iso8601(date)
  defp iso_date(_none), do: nil

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp iso(other) when is_binary(other), do: other
end
