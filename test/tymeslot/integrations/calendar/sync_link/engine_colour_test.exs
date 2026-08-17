defmodule Tymeslot.Integrations.Calendar.SyncLink.EngineColourTest do
  @moduledoc """
  Painting a link's `mirror_colour` onto the placeholder it writes.

  The colour is a second provider call, not a field on the mirror write, and
  both halves of that decision are pinned here.

  The first is that only Google can receive it. `patch_event_colour/4` lives on
  `Google.GoogleCalendarApi` alone and is not part of the shared `Provider`
  behaviour, so there is no polymorphic call to make; every other target has to
  decline by name rather than by attempting a request that cannot work. The
  Outlook case asserts that the hard way, by setting no expectation for the
  patch at all — `verify_on_exit!` fails the test if the engine reaches for a
  colour endpoint that does not exist.

  The second is that a failed patch must not fail the mirror. By the time the
  colour is applied the placeholder is already on the target blocking the time
  it exists to block; propagating the error would have Oban retry the whole
  mirror and re-send that placeholder to fix nothing but a hue. The test that
  earns its keep here is the one where the patch returns an error and
  `mirror/3` still answers `:ok` with an `active` mapping.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :sync_links

  import ExUnit.CaptureLog
  import Mox
  import Tymeslot.Factory
  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
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

  describe "mirror/3 — mirror colour" do
    # The link is re-read through `CalendarSyncLinkQueries.get/1` because that
    # is what the worker does, and it is the call that preloads
    # `target_integration` — the association the colour decision reads to learn
    # which provider it is writing to.
    setup %{link: link} do
      {:ok, loaded} = CalendarSyncLinkQueries.get(link.id)
      %{link: loaded}
    end

    test "paints the link's colour onto the placeholder after a Google write", %{
      user: user,
      source: source,
      target: target,
      link: link
    } do
      link = %{link | mirror_colour: "peacock"}

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        oauth_write_response("target-pid-1")
      end)

      expect(Tymeslot.CalendarMock, :update_event, fn uid, event_data, context ->
        assert context == {target.id, user.id}
        assert uid == Engine.target_uid_for(link.id, "source-uid-1")
        assert event_data.colour_only == true
        assert event_data.colour == "peacock"
        assert event_data.provider_event_id == "target-pid-1"
        :ok
      end)

      assert :ok == Engine.mirror(link, source_event(source), user.id)
    end

    test "a link with no colour makes no extra provider call", %{
      user: user,
      source: source,
      link: link
    } do
      link = %{link | mirror_colour: nil}

      # No `update_event` expectation: `verify_on_exit!` fails the test if the
      # engine patches a colour that was never configured.
      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        oauth_write_response("target-pid-1")
      end)

      assert :ok == Engine.mirror(link, source_event(source), user.id)
    end

    # Google's patch answers `{:ok, event}`, not a bare `:ok`.
    # `patch_event_colour/4` returns the provider body, `handle_write_api_call/2`
    # pipes it through `convert_event/1` — atom keys, the provider's id under
    # `:uid` — and hands back `{:ok, converted}`. A bare `:ok` comes back only
    # from the short-circuit for a colour that maps to no Google `colorId`, so a
    # patch that actually reached the API and worked never looks like one.
    #
    # Google is also the only provider that reaches this path at all
    # (`Capability.supports?/2` on `:per_event_colour`), which makes `{:ok, _}`
    # the shape a *successful* patch has in production and the bare `:ok` the
    # rare one. Matching only the bare `:ok` therefore logged every real success
    # as a failure, and the log is the only thing this path emits.
    test "a Google patch answering {:ok, event} is not logged as a failure", %{
      user: user,
      source: source,
      link: link
    } do
      link = %{link | mirror_colour: "peacock"}

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        oauth_write_response("target-pid-1")
      end)

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context ->
        {:ok,
         %{
           uid: "target-pid-1",
           summary: "Busy",
           start_time: ~U[2026-07-03 09:00:00Z],
           end_time: ~U[2026-07-03 10:00:00Z],
           etag: "\"3141592653589793\""
         }}
      end)

      log =
        capture_log(fn ->
          assert :ok == Engine.mirror(link, source_event(source), user.id)
        end)

      refute log =~ "Mirror colour patch failed"
    end

    test "a colour patch that really fails is still reported", %{
      user: user,
      source: source,
      link: link
    } do
      link = %{link | mirror_colour: "peacock"}

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        oauth_write_response("target-pid-1")
      end)

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context ->
        {:error, :rate_limited}
      end)

      log =
        capture_log(fn ->
          assert :ok == Engine.mirror(link, source_event(source), user.id)
        end)

      assert log =~ "Mirror colour patch failed"
    end

    test "a failing colour patch still leaves the mirror successful", %{
      user: user,
      source: source,
      link: link
    } do
      link = %{link | mirror_colour: "peacock"}

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        oauth_write_response("target-pid-1")
      end)

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context ->
        {:error, :rate_limited}
      end)

      # The placeholder is on the target and blocking time, which is the whole
      # point of the write. Returning an error here would have Oban retry the
      # mirror — re-sending the placeholder — to fix nothing but its colour.
      assert :ok == Engine.mirror(link, source_event(source), user.id)

      assert {:ok, mirror} =
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "source-uid-1")

      assert mirror.state == "active"
    end

    test "repaints on update, so a colour change reaches an existing placeholder", %{
      user: user,
      source: source,
      link: link
    } do
      link = %{link | mirror_colour: "grape"}

      mirror_for_link(link,
        source_uid: "source-uid-1",
        target_uid: Engine.target_uid_for(link.id, "source-uid-1"),
        target_provider_event_id: "target-pid-1"
      )

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, event_data, _context ->
        refute Map.has_key?(event_data, :colour_only)
        :ok
      end)

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, event_data, _context ->
        assert event_data.colour_only == true
        assert event_data.colour == "grape"
        :ok
      end)

      assert :ok == Engine.mirror(link, source_event(source), user.id)
    end

    test "a failed mirror write never reaches the colour patch", %{
      user: user,
      source: source,
      link: link
    } do
      link = %{link | mirror_colour: "peacock"}

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:error, :rate_limited}
      end)

      assert {:error, :rate_limited} == Engine.mirror(link, source_event(source), user.id)
    end
  end

  describe "mirror/3 — mirror colour on a provider without per-event colour" do
    setup %{user: user, source: source} do
      target = insert(:calendar_integration, user: user, provider: "outlook")

      link =
        insert(:calendar_sync_link,
          user_id: user.id,
          source_integration_id: source.id,
          target_integration_id: target.id,
          mirror_colour: "peacock"
        )

      {:ok, loaded} = CalendarSyncLinkQueries.get(link.id)

      %{outlook_target: target, outlook_link: loaded}
    end

    test "discards the colour patch rather than attempting it", %{
      user: user,
      source: source,
      outlook_link: link
    } do
      # Only the mirror write itself is expected. Microsoft Graph exposes no
      # per-event colour, so a patch could never succeed and is never sent.
      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        oauth_write_response("target-pid-1")
      end)

      assert :ok == Engine.mirror(link, source_event(source), user.id)
    end

    test "the mirror is still written and recorded", %{
      user: user,
      source: source,
      outlook_link: link
    } do
      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        oauth_write_response("target-pid-1")
      end)

      assert :ok == Engine.mirror(link, source_event(source), user.id)

      assert {:ok, mirror} =
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "source-uid-1")

      assert mirror.state == "active"
    end
  end

  describe "colour_target/1" do
    test "names Google as the only provider with a per-event colour", %{link: link} do
      {:ok, link} = CalendarSyncLinkQueries.get(link.id)

      assert {:ok, "peacock"} ==
               Engine.colour_target(%{link | mirror_colour: "peacock"})
    end

    test "discards on a provider with no per-event colour", %{user: user, source: source} do
      target = insert(:calendar_integration, user: user, provider: "outlook")

      link =
        insert(:calendar_sync_link,
          user_id: user.id,
          source_integration_id: source.id,
          target_integration_id: target.id,
          mirror_colour: "peacock"
        )

      {:ok, loaded} = CalendarSyncLinkQueries.get(link.id)

      assert {:discard, :provider_has_no_event_colour} == Engine.colour_target(loaded)
    end

    test "discards when the link carries no colour", %{link: link} do
      {:ok, link} = CalendarSyncLinkQueries.get(link.id)

      assert {:discard, :no_mirror_colour} == Engine.colour_target(%{link | mirror_colour: nil})
      assert {:discard, :no_mirror_colour} == Engine.colour_target(%{link | mirror_colour: ""})
    end

    test "a link whose target was never preloaded is named as its own case", %{link: link} do
      # The factory link carries `target_integration` unloaded. Reporting this
      # as an unsupported provider would point an investigation at the provider
      # rather than at the caller that skipped the preload.
      assert {:discard, :target_integration_not_loaded} ==
               Engine.colour_target(%{link | mirror_colour: "peacock"})
    end
  end
end
