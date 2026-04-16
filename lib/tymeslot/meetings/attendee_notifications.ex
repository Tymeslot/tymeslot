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
    * `attendees_added/2` / `attendees_removed/2` — immediate send path for
      membership-only changes (method `:request` or `:cancel` respectively).
    * `event_deleted/2` — returns `{:needs_confirmation, count}` so the caller
      knows to show a confirmation prompt; `{:ok, :no_attendees}` if there is
      nobody to notify.
    * `event_deleted_confirm/2` — delegates to Dispatcher for debounced send.
    * `pending?/1` / `cancel_pending/1` — inspection and cancellation of the
      debounced pipeline for either event kind.

  The debounced update/delete path is owned by `Dispatcher`. This module does
  not itself know anything about Oban.
  """

  alias Tymeslot.Emails.EmailScheduler.CalendarScheduler
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Meetings.AttendeeNotifications.ChangeDetector
  alias Tymeslot.Meetings.AttendeeNotifications.ChangeSummary
  alias Tymeslot.Meetings.AttendeeNotifications.Dispatcher
  alias Tymeslot.Meetings.AttendeeNotifications.IcalMethod
  alias Tymeslot.Meetings.MeetingSchema

  @type event :: map
  @type attendee :: %{optional(:email) => String.t(), optional(:name) => String.t() | nil}

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

  @spec event_deleted(event, [attendee]) ::
          {:ok, :no_attendees} | {:needs_confirmation, non_neg_integer}
  def event_deleted(_event, []), do: {:ok, :no_attendees}

  def event_deleted(_event, attendees) when is_list(attendees) do
    {:needs_confirmation, length(attendees)}
  end

  @spec event_deleted_confirm(event, [attendee]) :: {:ok, :sent} | {:error, term}
  def event_deleted_confirm(event, _attendees) do
    case Dispatcher.schedule_delete(event_id(event), event_kind(event)) do
      {:ok, :scheduled} -> {:ok, :sent}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec pending?(integer | binary) :: boolean
  def pending?(event_id) when is_integer(event_id) do
    Dispatcher.pending?(event_id, :meeting) or
      Dispatcher.pending?(event_id, :provider_calendar_event)
  end

  def pending?(event_id) when is_binary(event_id) do
    case Integer.parse(event_id) do
      {int_id, ""} -> pending?(int_id)
      _other -> false
    end
  end

  @spec cancel_pending(event) :: :ok
  def cancel_pending(event) do
    Dispatcher.cancel_pending(event_id(event), event_kind(event))
  end

  ## Internal helpers

  defp send_immediate(event, attendees, method, sequence) do
    Enum.each(attendees, fn attendee ->
      CalendarScheduler.schedule_calendar_invitation(%{
        user_id: user_id_for(event),
        attendee_email: Map.get(attendee, :email),
        event_title: title_for(event),
        event_uid: Map.get(event, :uid),
        event_start_at: iso(start_at_for(event)),
        event_end_at: iso(end_at_for(event)),
        event_location: Map.get(event, :location),
        event_description: Map.get(event, :description),
        method: method,
        sequence: sequence
      })
    end)

    :ok
  end

  defp to_event_map(event, attendees) do
    %{
      title: title_for(event),
      starts_at: start_at_for(event),
      ends_at: end_at_for(event),
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

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp iso(other) when is_binary(other), do: other
end
