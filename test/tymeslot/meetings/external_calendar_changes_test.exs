defmodule Tymeslot.Meetings.ExternalCalendarChangesTest do
  @moduledoc """
  An external deletion whose auto-cancel loses to a cancellation made
  through another path (the guest, the host, a second sync) while the
  deletion was being handled.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :meetings

  import Mox

  alias Tymeslot.Clock
  alias Tymeslot.Meetings.ExternalCalendarChanges
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.TestMocks

  @armed_key :cancel_after_sync_status_update

  setup :verify_on_exit!

  setup do
    TestMocks.setup_email_mocks()

    handler_id = "external-calendar-changes-test-#{inspect(make_ref())}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:tymeslot, :repo, :query],
        &__MODULE__.cancel_once_sync_status_is_recorded/4,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    user = insert(:user)
    integration = insert(:calendar_integration, user: user)

    meeting =
      insert(:meeting,
        organizer_user: user,
        calendar_integration_id: integration.id,
        provider_event_id: "provider-event-#{System.unique_integer([:positive])}"
      )

    %{meeting: meeting}
  end

  test "treats a cancellation that won the race as done, and keeps the deletion recorded",
       %{meeting: meeting} do
    Process.put(@armed_key, {:after_update, meeting.id})

    assert :ok = ExternalCalendarChanges.apply_change_to_meeting(meeting, :deleted)

    # The race was actually staged: the competing cancellation committed.
    refute Process.get(@armed_key)

    assert {:ok, reloaded} = MeetingQueries.get_meeting(meeting.id)
    assert reloaded.status == "cancelled"
    # A failed auto-cancel clears the status so the next sync retries; a lost
    # race must not, since there is nothing left to retry.
    assert reloaded.calendar_sync_status == "externally_deleted"
    assert is_nil(reloaded.cancellation_reason)
  end

  # Runs in the calling process. Once the external deletion is recorded, the
  # auto-cancel re-reads the meeting and then writes; a concurrent
  # cancellation committing between that read and that write is the race.
  @doc false
  @spec cancel_once_sync_status_is_recorded(list(), map(), map(), term()) :: term()
  def cancel_once_sync_status_is_recorded(_event, _measurements, metadata, _config) do
    case {Process.get(@armed_key), metadata[:source], metadata[:query]} do
      {{:after_update, meeting_id}, "meetings", "UPDATE " <> _rest = query} ->
        if query =~ ~r/SET "calendar_sync_status"/,
          do: Process.put(@armed_key, {:after_read, meeting_id})

      {{:after_read, meeting_id}, "meetings", "SELECT " <> _rest} ->
        Process.delete(@armed_key)

        {:ok, _cancelled} =
          MeetingQueries.transition_to_cancelled(meeting_id,
            cancelled_at: DateTime.truncate(Clock.utc_now(), :second)
          )

      _other ->
        :ok
    end
  end
end
