defmodule Tymeslot.Integrations.Calendar.SyncLink.EngineTest do
  @moduledoc """
  The mirror write itself: create, update, delete, and what happens when a
  provider call succeeds but the bookkeeping does not.

  Orphan compensation is the test that earns its keep. Google and Outlook assign
  event ids server-side, so a create that lands on the provider while the mirror
  row fails to persist leaves a placeholder nothing points at — and the Oban
  retry, finding no mapping, creates a second one. Deleting the just-created
  event before surfacing the error is what keeps the retry idempotent, and the
  only way to see it happen is to assert the delete call.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :sync_links

  import Mox
  import Tymeslot.Factory
  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorQueries
  alias Tymeslot.Integrations.Calendar.SyncLink.Engine

  setup :verify_on_exit!

  setup do
    linked_pair()
  end

  defp source_event(source, attrs \\ %{}) do
    CalendarEvent.new!(
      Map.merge(
        %{
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
        },
        attrs
      )
    )
  end

  describe "target_uid_for/2" do
    test "is deterministic in the link and the source UID, so a PUT converges", %{link: link} do
      first = Engine.target_uid_for(link.id, "source-uid-1")
      again = Engine.target_uid_for(link.id, "source-uid-1")

      assert first == again
    end

    test "differs per source event and per link", %{link: link} do
      other = insert(:calendar_sync_link)

      refute Engine.target_uid_for(link.id, "a") == Engine.target_uid_for(link.id, "b")
      refute Engine.target_uid_for(link.id, "a") == Engine.target_uid_for(other.id, "a")
    end
  end

  describe "mirror/3 — first write" do
    test "creates the placeholder and records the mapping", %{
      user: user,
      source: source,
      target: target,
      link: link
    } do
      expect(Tymeslot.CalendarMock, :create_event, fn event_data, context ->
        assert context == {target.id, user.id}
        assert event_data.summary == "Busy"
        assert event_data.start_time == ~U[2026-07-03 09:00:00Z]
        refute Map.has_key?(event_data, :description)
        {:ok, %{provider_event_id: "target-pid-1", uid: event_data.uid}}
      end)

      assert :ok == Engine.mirror(link, source_event(source), user.id)

      assert {:ok, mirror} =
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "source-uid-1")

      assert mirror.target_integration_id == target.id
      assert mirror.target_uid == Engine.target_uid_for(link.id, "source-uid-1")
      assert mirror.target_provider_event_id == "target-pid-1"
      assert mirror.state == "active"
      assert mirror.last_synced_at
    end

    test "an all-day source produces a date-valued placeholder", %{
      user: user,
      source: source,
      link: link
    } do
      event =
        source_event(source, %{
          all_day: true,
          start_at: nil,
          end_at: nil,
          start_date: ~D[2026-07-03],
          end_date: ~D[2026-07-06]
        })

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        assert event_data.all_day == true
        assert event_data.start_time == ~D[2026-07-03]
        assert event_data.end_time == ~D[2026-07-06]
        {:ok, %{provider_event_id: "target-pid-1"}}
      end)

      assert :ok == Engine.mirror(link, event, user.id)
    end

    test "a provider failure surfaces as an error and writes no mapping", %{
      user: user,
      source: source,
      link: link
    } do
      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:error, :rate_limited}
      end)

      assert {:error, :rate_limited} == Engine.mirror(link, source_event(source), user.id)

      assert {:error, :not_found} ==
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "source-uid-1")
    end
  end

  describe "mirror/3 — orphan compensation" do
    test "deletes the just-created provider event when the mapping cannot be persisted", %{
      user: user,
      source: source,
      target: target,
      link: link
    } do
      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:ok, %{provider_event_id: "orphan-pid"}}
      end)

      expect(Tymeslot.CalendarMock, :delete_event, fn uid, context, _opts ->
        send(test_pid, {:compensated, uid, context})
        :ok
      end)

      # A link id that no longer exists makes the mirror insert fail on its
      # foreign key — the same class of failure as the database being
      # unavailable, without needing to take it away.
      doomed = %{link | id: link.id + 10_000}

      assert {:error, _reason} = Engine.mirror(doomed, source_event(source), user.id)

      assert_received {:compensated, orphan_uid, {target_id, user_id}}
      assert target_id == target.id
      assert user_id == user.id
      assert orphan_uid == Engine.target_uid_for(doomed.id, "source-uid-1")
    end

    test "a failed compensating delete does not mask the persistence error", %{
      user: user,
      source: source,
      link: link
    } do
      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:ok, %{provider_event_id: "orphan-pid"}}
      end)

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
        {:error, :service_unavailable}
      end)

      doomed = %{link | id: link.id + 10_000}

      assert {:error, reason} = Engine.mirror(doomed, source_event(source), user.id)
      refute reason == :service_unavailable
    end
  end

  describe "mirror/3 — subsequent writes" do
    test "updates the existing placeholder rather than creating a second", %{
      user: user,
      source: source,
      target: target,
      link: link
    } do
      target_uid = Engine.target_uid_for(link.id, "source-uid-1")

      mirror_for_link(link,
        source_uid: "source-uid-1",
        target_uid: target_uid,
        target_provider_event_id: "target-pid-1"
      )

      expect(Tymeslot.CalendarMock, :update_event, fn uid, event_data, context ->
        assert uid == target_uid
        assert context == {target.id, user.id}
        assert event_data.summary == "Busy"
        assert event_data.start_time == ~U[2026-07-03 09:00:00Z]
        :ok
      end)

      assert :ok == Engine.mirror(link, source_event(source), user.id)

      assert {:ok, mirror} =
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "source-uid-1")

      assert mirror.state == "active"
    end

    test "an update failure marks the mapping failed and surfaces the error", %{
      user: user,
      source: source,
      link: link
    } do
      mirror_for_link(link,
        source_uid: "source-uid-1",
        target_uid: Engine.target_uid_for(link.id, "source-uid-1")
      )

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context ->
        {:error, :timeout}
      end)

      assert {:error, :timeout} == Engine.mirror(link, source_event(source), user.id)

      assert {:ok, mirror} =
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "source-uid-1")

      assert mirror.state == "failed"
    end
  end

  describe "unmirror/3" do
    test "deletes the placeholder and drops the mapping", %{
      user: user,
      target: target,
      link: link
    } do
      target_uid = Engine.target_uid_for(link.id, "source-uid-1")
      mirror_for_link(link, source_uid: "source-uid-1", target_uid: target_uid)

      expect(Tymeslot.CalendarMock, :delete_event, fn uid, context, _opts ->
        assert uid == target_uid
        assert context == {target.id, user.id}
        :ok
      end)

      assert :ok == Engine.unmirror(link, "source-uid-1", user.id)

      assert {:error, :not_found} ==
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "source-uid-1")
    end

    test "a placeholder the provider no longer has still drops the mapping", %{
      user: user,
      link: link
    } do
      mirror_for_link(link,
        source_uid: "source-uid-1",
        target_uid: Engine.target_uid_for(link.id, "source-uid-1")
      )

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
        {:error, :not_found}
      end)

      assert :ok == Engine.unmirror(link, "source-uid-1", user.id)

      assert {:error, :not_found} ==
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "source-uid-1")
    end

    test "a failed delete leaves the mapping behind so the placeholder can be found again", %{
      user: user,
      link: link
    } do
      mirror_for_link(link,
        source_uid: "source-uid-1",
        target_uid: Engine.target_uid_for(link.id, "source-uid-1")
      )

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
        {:error, :service_unavailable}
      end)

      assert {:error, :service_unavailable} == Engine.unmirror(link, "source-uid-1", user.id)

      assert {:ok, mirror} =
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "source-uid-1")

      assert mirror.state == "pending_delete"
    end

    test "a placeholder deleted on the target is written again, not abandoned", %{
      user: user,
      source: source,
      link: link
    } do
      # The organiser sees an unexplained "Busy" block on their second calendar
      # and deletes it. The source event is untouched, so the next pass still
      # believes a placeholder exists and updates it — against an event the
      # provider no longer has.
      #
      # Abandoning it there is the worst outcome available: the slot is bookable
      # for the rest of the event's life while Tymeslot's own mapping insists it
      # is covered, and nothing reads the state that records the failure. The
      # source is still the truth, so the placeholder is recreated — the same
      # update→create-on-404 recovery `Meetings.CalendarEventSync` performs.
      mirror_for_link(link,
        source_uid: "source-uid-1",
        target_uid: Engine.target_uid_for(link.id, "source-uid-1"),
        target_provider_event_id: "gone-from-the-target"
      )

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context ->
        {:error, :not_found}
      end)

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:ok, %{provider_event_id: "recreated-pid"}}
      end)

      assert :ok == Engine.mirror(link, source_event(source), user.id)

      assert {:ok, mirror} =
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "source-uid-1")

      assert mirror.state == "active"
      assert mirror.target_provider_event_id == "recreated-pid"
    end

    test "a mirror being torn down is not rewritten by an ordinary sync", %{
      user: user,
      source: source,
      link: link
    } do
      # The state a failed teardown leaves behind: a link removed or a calendar
      # disconnected, whose provider delete did not land, with the sweep already
      # retrying it. The source event is untouched, so the push path still
      # enqueues an upsert for it.
      mirror_for_link(link,
        source_uid: "source-uid-1",
        target_uid: Engine.target_uid_for(link.id, "source-uid-1"),
        state: "pending_delete"
      )

      # No expectation set: reaching the provider at all fails this through
      # verify_on_exit!. Rewriting the placeholder would undo a withdrawal that
      # is still in progress, and the two paths would then fight — the sweep
      # deleting while the push path rewrites.
      assert {:discard, :mirror_pending_delete} ==
               Engine.mirror(link, source_event(source), user.id)

      assert {:ok, mirror} =
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "source-uid-1")

      assert mirror.state == "pending_delete"
    end

    test "nothing to unmirror is not an error", %{user: user, link: link} do
      assert :ok == Engine.unmirror(link, "never-mirrored", user.id)
    end
  end

  describe "mirror/3 — privacy tiers" do
    setup %{link: link} do
      %{
        tiered: fn attrs ->
          %{link | privacy_tier: attrs[:privacy_tier], generic_label: attrs[:generic_label]}
        end
      }
    end

    test "busy_only writes the placeholder title", %{
      user: user,
      source: source,
      link: link,
      tiered: tiered
    } do
      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        assert event_data.summary == "Busy"
        refute Map.has_key?(event_data, :description)
        {:ok, %{provider_event_id: "target-pid-1"}}
      end)

      assert :ok ==
               Engine.mirror(
                 tiered.(privacy_tier: "busy_only", generic_label: nil),
                 source_event(source, %{summary: "Board meeting", description: "Agenda"}),
                 user.id
               )

      assert {:ok, _mirror} =
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "source-uid-1")
    end

    test "generic_label writes the organiser's label", %{
      user: user,
      source: source,
      tiered: tiered
    } do
      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        assert event_data.summary == "Personal commitment"
        refute Map.has_key?(event_data, :description)
        refute inspect(event_data) =~ "Board meeting"
        {:ok, %{provider_event_id: "target-pid-1"}}
      end)

      assert :ok ==
               Engine.mirror(
                 tiered.(privacy_tier: "generic_label", generic_label: "Personal commitment"),
                 source_event(source, %{summary: "Board meeting", description: "Agenda"}),
                 user.id
               )
    end

    test "full_passthrough copies title, description and location", %{
      user: user,
      source: source,
      tiered: tiered
    } do
      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        assert event_data.summary == "Board meeting"
        assert event_data.description == "Agenda"
        assert event_data.location == "Room 4"
        {:ok, %{provider_event_id: "target-pid-1"}}
      end)

      assert :ok ==
               Engine.mirror(
                 tiered.(privacy_tier: "full_passthrough", generic_label: nil),
                 source_event(source, %{
                   summary: "Board meeting",
                   description: "Agenda",
                   location: "Room 4"
                 }),
                 user.id
               )
    end

    test "a private source is rendered busy_only even on full_passthrough", %{
      user: user,
      source: source,
      tiered: tiered
    } do
      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        assert event_data.summary == "Busy"
        refute Map.has_key?(event_data, :description)
        refute inspect(event_data) =~ "Board meeting"
        {:ok, %{provider_event_id: "target-pid-1"}}
      end)

      assert :ok ==
               Engine.mirror(
                 tiered.(privacy_tier: "full_passthrough", generic_label: nil),
                 source_event(source, %{
                   summary: "Board meeting",
                   description: "Agenda",
                   visibility: :private
                 }),
                 user.id
               )
    end

    test "no tier sends attendees to the provider", %{user: user, source: source, tiered: tiered} do
      for {tier, label} <- [
            {"busy_only", nil},
            {"generic_label", "Personal commitment"},
            {"full_passthrough", nil}
          ] do
        expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
          refute Map.has_key?(event_data, :attendees)
          refute inspect(event_data) =~ "colleague@example.com"
          {:ok, %{provider_event_id: "target-pid-1"}}
        end)

        event =
          source_event(source, %{
            uid: "attendee-uid-#{tier}",
            summary: "Board meeting",
            attendees: [%{email: "colleague@example.com", name: "A Colleague"}]
          })

        assert :ok ==
                 Engine.mirror(tiered.(privacy_tier: tier, generic_label: label), event, user.id)
      end
    end

    test "the tier is applied on update as well as on create", %{
      user: user,
      source: source,
      link: link,
      tiered: tiered
    } do
      mirror_for_link(link,
        source_uid: "source-uid-1",
        target_uid: Engine.target_uid_for(link.id, "source-uid-1")
      )

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, event_data, _context ->
        assert event_data.summary == "Personal commitment"
        :ok
      end)

      assert :ok ==
               Engine.mirror(
                 tiered.(privacy_tier: "generic_label", generic_label: "Personal commitment"),
                 source_event(source, %{summary: "Board meeting"}),
                 user.id
               )
    end
  end
end
