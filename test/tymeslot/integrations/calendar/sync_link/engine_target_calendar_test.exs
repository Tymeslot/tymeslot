defmodule Tymeslot.Integrations.Calendar.SyncLink.EngineTargetCalendarTest do
  @moduledoc """
  Every write a link makes must address the calendar the link names.

  A link may point at a secondary calendar — `target_calendar_id` — and the
  create path has always honoured it. The delete and the colour patch did not:
  both fell through to the integration's default booking calendar. The create
  therefore wrote the placeholder to one calendar and the delete asked a
  *different* one to remove it, which answers 404. That 404 is read as "already
  gone" and drops the mapping row, destroying the only record of where the
  placeholder actually is — so the busy block is stranded on the organiser's
  calendar with nothing left that can name it.

  The assertions here are on the calendar id reaching the provider, not on the
  mapping row alone: a test that only checked the row would pass against
  exactly the broken behaviour this file exists to prevent.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :sync_links

  import Mox
  import Tymeslot.Factory
  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorSchema
  alias Tymeslot.Integrations.Calendar.SyncLink.Engine
  alias Tymeslot.Repo

  setup :verify_on_exit!

  setup do
    linked_pair()
  end

  @secondary "team-calendar@group.calendar.google.com"

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

  # The link as the worker sees it: re-read so `target_integration` is preloaded
  # (the colour decision reads it) and pointed at a secondary calendar.
  defp secondary_link(link) do
    {:ok, loaded} = CalendarSyncLinkQueries.get(link.id)
    %{loaded | target_calendar_id: @secondary}
  end

  defp mirror_row(link, target_uid) do
    mirror_for_link(link, source_uid: "source-uid-1", target_uid: target_uid)
  end

  describe "unmirror/4 on a link with a secondary target calendar" do
    test "deletes the placeholder from the link's calendar, not the default", %{
      user: user,
      target: target,
      link: link
    } do
      link = secondary_link(link)
      target_uid = Engine.target_uid_for(link.id, "source-uid-1")
      mirror = mirror_row(link, target_uid)
      test_pid = self()

      expect(Tymeslot.CalendarMock, :delete_event, fn uid, context, opts ->
        send(test_pid, {:deleted, uid, context, opts})
        :ok
      end)

      assert :ok == Engine.unmirror(link, "source-uid-1", user.id)

      assert_received {:deleted, ^target_uid, {target_id, user_id}, opts}
      assert target_id == target.id
      assert user_id == user.id

      assert opts[:calendar_id] == @secondary,
             "the delete must address the calendar the link writes to"

      refute Repo.get(CalendarSyncMirrorSchema, mirror.id)
    end

    test "a 404 from the correct calendar still drops the mapping", %{
      user: user,
      link: link
    } do
      link = secondary_link(link)
      target_uid = Engine.target_uid_for(link.id, "source-uid-1")
      mirror = mirror_row(link, target_uid)
      test_pid = self()

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, opts ->
        send(test_pid, {:calendar_id, opts[:calendar_id]})
        {:error, :not_found}
      end)

      assert :ok == Engine.unmirror(link, "source-uid-1", user.id)

      # The 404 only means "gone" because it came from the right calendar.
      assert_received {:calendar_id, @secondary}
      refute Repo.get(CalendarSyncMirrorSchema, mirror.id)
    end
  end

  describe "orphan compensation on a link with a secondary target calendar" do
    test "deletes the just-created placeholder from the link's calendar", %{
      user: user,
      source: source,
      link: link
    } do
      link = secondary_link(link)
      test_pid = self()

      # Force the mapping insert to fail *after* the provider create, which is
      # the whole hazard. The link id names no link row, so the mapping's
      # foreign key is rejected as a changeset error — the shape
      # `persist_or_compensate/5` branches on. The alternatives all miss: a bad
      # `target_integration_id` fails earlier at context resolution, an
      # over-long uid *raises* instead of returning an error tuple, and a
      # pre-existing row diverts the engine to the update path — none of which
      # ever creates a placeholder to orphan.
      link = %{link | id: link.id + 10_000}
      target_uid = Engine.target_uid_for(link.id, "source-uid-1")

      expect(Tymeslot.CalendarMock, :create_event, fn data, _context ->
        assert data.calendar_id == @secondary
        {:ok, %{provider_event_id: "target-pid-1"}}
      end)

      expect(Tymeslot.CalendarMock, :delete_event, fn uid, _context, opts ->
        send(test_pid, {:compensated, uid, opts[:calendar_id]})
        :ok
      end)

      assert {:error, _reason} = Engine.mirror(link, source_event(source), user.id)

      assert_received {:compensated, ^target_uid, @secondary}
    end
  end

  describe "the colour patch on a link with a secondary target calendar" do
    test "patches the colour on the link's calendar", %{
      user: user,
      source: source,
      link: link
    } do
      link = %{secondary_link(link) | mirror_colour: "peacock"}
      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:ok, %{provider_event_id: "target-pid-1"}}
      end)

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, event_data, _context ->
        send(test_pid, {:painted, event_data[:calendar_id]})
        :ok
      end)

      assert :ok == Engine.mirror(link, source_event(source), user.id)

      assert_received {:painted, @secondary},
                      "the colour patch must address the calendar holding the placeholder"
    end
  end
end
