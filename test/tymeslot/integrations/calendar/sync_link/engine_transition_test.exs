defmodule Tymeslot.Integrations.Calendar.SyncLink.EngineTransitionTest do
  @moduledoc """
  A placeholder already on the target, rewritten when the source *changes kind*.

  Every other test of the write path starts a source in its final state and
  asserts the first placeholder is right. That leaves the transitions untested,
  and they are where the interesting failures live: the update rebuilds the
  payload wholesale, so a source that changes kind has to overwrite a
  placeholder describing the *old* kind rather than merely differing from it.

  Two matter, for different reasons.

  Timed to all-day means the provider must convert an existing event's DTSTART
  from a date-time to a date in place. `update_mirror/7` treats any success
  shape as correct and re-baselines, so a provider that quietly ignored the
  conversion would leave a placeholder blocking the wrong span with a mapping
  row insisting it is current.

  Public to private is a privacy question. `MirrorPayload` forces `busy_only`
  for a private source whatever the link's tier says, and the tests for that
  all start private — so nothing asserted that a title *already written* to the
  target is replaced when the organiser marks the event private afterwards.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :sync_links

  import Mox
  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Integrations.Calendar.SyncLink.Engine

  setup :verify_on_exit!
  setup do: linked_pair()

  # The same shape `engine_test.exs` builds: a real `CalendarEvent`, which is
  # what the sync path hands the engine.
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

  # Puts the placeholder on the target and returns the mapping, so each test
  # below starts from a link that has already written once.
  defp already_mirrored(link, user, event) do
    expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
      {:ok, %{uid: "target-provider-id", summary: "Busy"}}
    end)

    assert :ok == Engine.mirror(link, event, user.id)
    :ok
  end

  describe "a source that switches between timed and all-day" do
    test "a timed placeholder is rewritten as a date-valued one", %{
      user: user,
      source: source,
      link: link
    } do
      already_mirrored(link, user, source_event(source))

      test_pid = self()

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, event_data, _context ->
        send(test_pid, {:payload, event_data})
        {:ok, %{uid: "target-provider-id"}}
      end)

      all_day =
        source_event(source, %{
          all_day: true,
          start_at: nil,
          end_at: nil,
          start_date: ~D[2026-07-03],
          end_date: ~D[2026-07-06]
        })

      assert :ok == Engine.mirror(link, all_day, user.id)

      assert_received {:payload, payload}

      # `%Date{}` rather than `%DateTime{}` is what every outbound mapper keys
      # off — Outlook's all-day check is literally a `match?(%Date{}, ...)` — so
      # the type, not the flag, is what makes the target write an all-day block.
      assert payload.all_day == true
      assert payload.start_time == ~D[2026-07-03]
      assert payload.end_time == ~D[2026-07-06]
    end

    test "an all-day placeholder is rewritten as a timed one", %{
      user: user,
      source: source,
      link: link
    } do
      already_mirrored(
        link,
        user,
        source_event(source, %{
          all_day: true,
          start_at: nil,
          end_at: nil,
          start_date: ~D[2026-07-03],
          end_date: ~D[2026-07-06]
        })
      )

      test_pid = self()

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, event_data, _context ->
        send(test_pid, {:payload, event_data})
        {:ok, %{uid: "target-provider-id"}}
      end)

      assert :ok == Engine.mirror(link, source_event(source), user.id)

      assert_received {:payload, payload}

      assert payload.all_day == false
      assert %DateTime{} = payload.start_time
      assert payload.start_time == ~U[2026-07-03 09:00:00Z]
    end
  end

  describe "a source made private after its placeholder was written" do
    setup %{link: link} do
      {:ok, link} =
        CalendarSyncLinkQueries.update(link, %{privacy_tier: "full_passthrough"})

      {:ok, link} = CalendarSyncLinkQueries.get(link.id)
      %{link: link}
    end

    test "the title already on the target is replaced with Busy", %{
      user: user,
      source: source,
      link: link
    } do
      # First write discloses the real title, which is what this tier is for.
      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        assert event_data.summary == "Board meeting"
        {:ok, %{uid: "target-provider-id", summary: "Board meeting"}}
      end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{summary: "Board meeting"}),
                 user.id
               )

      test_pid = self()

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, event_data, _context ->
        send(test_pid, {:payload, event_data})
        {:ok, %{uid: "target-provider-id"}}
      end)

      # The organiser marks it private. The tier on the link has not changed.
      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{summary: "Board meeting", visibility: "private"}),
                 user.id
               )

      assert_received {:payload, payload}

      # Overwritten, not merely omitted: the target already holds the real
      # title, so a payload that simply left `summary` out would leave it there.
      assert payload.summary == "Busy"
      refute Map.has_key?(payload, :description)
      refute Map.has_key?(payload, :location)
    end
  end
end
