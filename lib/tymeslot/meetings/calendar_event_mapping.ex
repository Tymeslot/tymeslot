defmodule Tymeslot.Meetings.CalendarEventMapping do
  @moduledoc """
  Records which provider event a meeting is synced to, once
  `Tymeslot.Meetings.CalendarEventSync` has created one, and cleans up after
  a create whose mapping cannot be kept.

  A meeting carries the event it owns as `calendar_uid` (the CalDAV family)
  or `provider_event_id` (every other provider), together with the
  integration and calendar path it was written to. An event the meeting does
  not end up carrying is an orphan a retry would duplicate, so it is deleted
  again, best effort, by the identifier the create returned.
  """

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  require Logger

  @doc """
  Persists the provider mapping after a successful create. If persistence
  fails, the provider event already exists but the meeting doesn't carry its
  UID/provider_event_id — so a worker retry of `create` would create a
  DUPLICATE (server-assigned-ID providers like Google/Outlook can't detect
  the orphan). To keep the operation idempotent we compensate by deleting the
  just-created event before surfacing the error, leaving the retry a clean
  slate. CalDAV PUTs are idempotent on the caller-supplied UID, so a failed
  delete there is harmless; the compensation primarily guards Google/Outlook.
  """
  @spec persist_or_compensate(MeetingSchema.t(), CreatedEvent.t()) :: :ok | {:error, term()}
  def persist_or_compensate(meeting, %CreatedEvent{} = created) do
    case persist(meeting, created, %{}) do
      :ok ->
        :ok

      {:error, reason} ->
        compensate_orphan(meeting, created)
        {:error, reason}
    end
  end

  @doc """
  Best-effort deletion of an event that was created on the provider but whose
  mapping could not be persisted. Uses the provider identifier returned by the
  create call so the delete targets the exact orphan, independent of whatever
  (stale, unpersisted) UID the meeting still carries.
  """
  @spec compensate_orphan(MeetingSchema.t(), CreatedEvent.t()) :: :ok
  def compensate_orphan(meeting, %CreatedEvent{} = created) do
    Logger.warning(
      "Calendar mapping persistence failed after create; deleting orphaned event to keep retry idempotent",
      meeting_id: meeting.id
    )

    discard(meeting, created)
  end

  @doc """
  Deletes an event just created on the provider that the meeting will not
  carry, by the identifier the create returned. Best effort: a failure is
  logged and still returns `:ok`.
  """
  @spec discard(MeetingSchema.t(), CreatedEvent.t()) :: :ok
  def discard(meeting, %CreatedEvent{} = created) do
    case CreatedEvent.local_uid(created) do
      nil -> :ok
      identifier -> delete_orphan(meeting, identifier)
    end
  end

  defp delete_orphan(meeting, identifier) do
    case CalendarEvents.delete_event(identifier, meeting) do
      :ok ->
        :ok

      {:error, :not_found} ->
        :ok

      other ->
        Logger.error("Failed to delete orphaned calendar event after persistence failure",
          meeting_id: meeting.id,
          result: LogFormat.reason(other)
        )

        :ok
    end
  end

  @doc """
  Persists which integration and calendar path were used for creation, with
  the provider's identifier for the new event. `base_attrs` go into the same
  write. With no integration to name, a plain create records nothing, as it
  always has; a write that carries `base_attrs` still records the new event,
  since a replacement must never leave the meeting on the event it is about
  to delete.
  """
  @spec persist(MeetingSchema.t(), CreatedEvent.t(), map()) :: :ok | {:error, term()}
  def persist(meeting, created, base_attrs) do
    case CalendarEvents.get_booking_integration_info(meeting) do
      {:ok, %{integration_id: integration_id, calendar_path: calendar_path}} ->
        attrs =
          Map.merge(base_attrs, %{
            calendar_integration_id: integration_id,
            calendar_path: calendar_path
          })

        write_calendar_mapping(meeting, put_provider_mapping(attrs, created))

      _no_integration_info when map_size(base_attrs) == 0 ->
        :ok

      _no_integration_info ->
        write_calendar_mapping(meeting, put_provider_mapping(base_attrs, created))
    end
  end

  defp write_calendar_mapping(meeting, attrs) do
    case MeetingQueries.update_meeting(meeting, attrs) do
      {:ok, _updated} ->
        :ok

      {:error, changeset} ->
        Logger.error("Failed to persist calendar mapping",
          meeting_id: meeting.id,
          error: LogFormat.reason(changeset.errors)
        )

        {:error, :calendar_mapping_persistence_failed}
    end
  end

  # A provider that reported an iCalendar UID (the CalDAV family) has confirmed
  # the value the meeting's event is keyed by, which is `calendar_uid`. It is
  # never written to `uid`: that is the booking's public identifier, already
  # embedded in the links the attendee was sent. Every other provider answers
  # with an identifier it minted, which belongs in `provider_event_id`:
  # writing it to `calendar_uid` would key the meeting by a value no sync ever
  # produces.
  #
  # A CalDAV create now also reports the resource's href, and that is
  # deliberately not persisted here. `calendar_event_identifier/1` hands
  # `provider_event_id` back as the uid of the next write, and an href is not
  # one. It belongs on the cached grid row, which addresses events by URL.
  defp put_provider_mapping(attrs, %CreatedEvent{uid: uid}) when is_binary(uid),
    do: Map.put(attrs, :calendar_uid, uid)

  defp put_provider_mapping(attrs, %CreatedEvent{provider_event_id: id}) when is_binary(id),
    do: Map.put(attrs, :provider_event_id, id)

  defp put_provider_mapping(attrs, %CreatedEvent{}), do: attrs
end
