defmodule Tymeslot.Integrations.Calendar.SyncLink.EngineAdoptionTest do
  @moduledoc """
  The 409 create→update fallback, and the identifier it records.

  Google reserves a deleted event's id, so a placeholder that was withdrawn
  leaves a tombstone and recreating it under the same deterministic id answers
  409 forever. The recovery is to update the id that already exists — but the
  update has to record the identifier the *provider* filed the event under, and
  the two provider families disagree about what that is.

  Getting it wrong is not cosmetic, and both consequences were live: 49 mapping
  rows recorded our internal uid where Google holds a hash of it, which left
  loop prevention unable to recognise the placeholder (so a real event grew a
  fresh "Busy" block on every sweep) and teardown unable to delete it.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :sync_links

  import Mox
  import Tymeslot.Factory
  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorQueries
  alias Tymeslot.Integrations.Calendar.Google.EventMapper
  alias Tymeslot.Integrations.Calendar.SyncLink.Eligibility
  alias Tymeslot.Integrations.Calendar.SyncLink.Engine

  setup :verify_on_exit!

  setup do
    linked_pair()
  end

  defp source_event(source) do
    CalendarEvent.new!(%{
      uid: "source-uid-1",
      calendar_integration_id: source.id,
      provider: :google,
      provider_calendar_id: "primary",
      provider_event_id: "source-pid-1",
      summary: "Board meeting",
      all_day: false,
      start_at: ~U[2026-07-03 09:00:00Z],
      end_at: ~U[2026-07-03 10:00:00Z],
      synced_at: ~U[2026-07-01 00:00:00Z]
    })
  end

  describe "mirror/3 — adopting a placeholder whose identifier is taken" do
    test "records the id Google filed the event under, not our internal uid", %{
      user: user,
      source: source,
      target: target,
      link: link
    } do
      target_uid = Engine.target_uid_for(link.id, "source-uid-1")
      google_id = EventMapper.uuid_to_google_event_id(target_uid)

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:error, :already_exists}
      end)

      # The shape a Google update really answers: `Provider.update_event/3`
      # pipes the response through `convert_event/1` exactly as `create_event`
      # does, landing the provider's own id under `uid`. Google filed the
      # placeholder under the *hashed* form of `target_uid`, never under
      # `target_uid` itself.
      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, context ->
        assert context == {target.id, user.id}
        {:ok, %{uid: google_id}}
      end)

      assert :ok == Engine.mirror(link, source_event(source), user.id)

      assert {:ok, mirror} =
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "source-uid-1")

      assert mirror.target_provider_event_id == google_id
      refute mirror.target_provider_event_id == target_uid
      assert mirror.target_uid == target_uid
      assert mirror.state == "active"
    end

    # The user-visible half of the defect. A placeholder whose provider id was
    # recorded wrongly is invisible to loop prevention: the cached event carries
    # Google's `{hash}@google.com` iCalUID, and a mirror set that contains
    # neither that nor anything matching it reads the placeholder as an ordinary
    # event — so it is mirrored back on the next sweep.
    test "the adopted placeholder is then recognised by loop prevention", %{
      user: user,
      source: source,
      target: target,
      link: link
    } do
      target_uid = Engine.target_uid_for(link.id, "source-uid-1")
      google_id = EventMapper.uuid_to_google_event_id(target_uid)

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:error, :already_exists}
      end)

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context ->
        {:ok, %{uid: google_id}}
      end)

      assert :ok == Engine.mirror(link, source_event(source), user.id)

      mirrors = CalendarSyncMirrorQueries.mirror_uids_for_integrations([target.id])

      # What the next inbound sync caches for that placeholder: the normaliser
      # prefers Google's `iCalUID`, which is the id it filed the event under
      # with `@google.com` appended.
      cached_placeholder = %{
        calendar_integration_id: target.id,
        uid: "#{google_id}@google.com"
      }

      refute Eligibility.worth_enqueueing?(cached_placeholder, mirrors)
    end

    # The same placeholder, found on the link's *source* instead. It gets there
    # when the target has lost its authorisation: `BookingIntegrationResolver`
    # falls back to the organiser's primary calendar, so the write lands on the
    # calendar the link reads from rather than the one it writes to.
    #
    # The set above cannot see it — `mirror_uids_for_integrations/1` is keyed on
    # the mirror's target, which is correct for the calendar grid and the agenda
    # and wrong for this question. The inbound sync therefore asks
    # `mirror_uids_for_sync/1`, which selects by *link* and so covers both ends.
    #
    # Without this the source's own sync read each placeholder as a fresh event
    # and mirrored it again, three generations inside two minutes on a live
    # calendar. The test above passed throughout, because it built the event's
    # integration and the mirror set from the same value.
    test "a placeholder that landed on the link's source is recognised too", %{
      user: user,
      source: source,
      link: link
    } do
      target_uid = Engine.target_uid_for(link.id, "source-uid-1")
      google_id = EventMapper.uuid_to_google_event_id(target_uid)

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:ok, %{uid: google_id}}
      end)

      assert :ok == Engine.mirror(link, source_event(source), user.id)

      on_the_source = %{
        calendar_integration_id: source.id,
        uid: "#{google_id}@google.com"
      }

      refute Eligibility.worth_enqueueing?(
               on_the_source,
               CalendarSyncMirrorQueries.mirror_uids_for_sync(source.id)
             ),
             "a placeholder redirected onto the link's source was treated as a fresh event"
    end

    # The constraint the fix must not break. The CalDAV family stores the UID it
    # is handed and answers a bare `:ok`, so there is no provider id to read
    # back — `target_uid` genuinely is the handle, and recording it is correct
    # here for exactly the reason it is wrong for Google.
    test "a CalDAV target, which keeps the caller's uid, still records the right id", %{
      user: user
    } do
      source = insert(:calendar_integration, user: user, provider: "google")
      target = insert(:calendar_integration, user: user, provider: "caldav")

      link =
        insert(:calendar_sync_link,
          user_id: user.id,
          source_integration_id: source.id,
          target_integration_id: target.id
        )

      target_uid = Engine.target_uid_for(link.id, "source-uid-1")

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:error, :already_exists}
      end)

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context -> :ok end)

      assert :ok == Engine.mirror(link, source_event(source), user.id)

      assert {:ok, mirror} =
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "source-uid-1")

      assert mirror.target_provider_event_id == target_uid
    end
  end
end
