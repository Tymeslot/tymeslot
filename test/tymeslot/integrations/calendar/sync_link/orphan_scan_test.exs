defmodule Tymeslot.Integrations.Calendar.SyncLink.OrphanScanTest do
  @moduledoc """
  Placeholders on a target that no mirror row claims.

  Every recovery path in this feature is keyed on the mapping row: teardown
  reads it, the reconcile sweep reads it, loop prevention is built from it. A
  row lost while its placeholder survives is therefore invisible to all of
  them — the busy block sits on the organiser's calendar with nothing able to
  update or remove it.

  Detection is separated from repair deliberately. Rebuilding a row means
  deciding which source event a placeholder belonged to, and acting on a wrong
  answer writes to somebody's calendar; reporting costs nothing and tells us
  whether the case occurs at all before anything is automated.

  The discriminator is the `tymeslot-mirror-` UID prefix, never the
  `createdBy: "tymeslot"` tag. That tag is on every event Tymeslot writes,
  including real bookings, so scanning by it would report an organiser's own
  meetings as orphans — and a later repair pass would delete them.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :sync_links

  import Tymeslot.Factory
  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Integrations.Calendar.Google.EventMapper
  alias Tymeslot.Integrations.Calendar.SyncLink.Engine
  alias Tymeslot.Integrations.Calendar.SyncLink.OrphanScan

  setup do: linked_pair()

  defp cached(integration, uid, attrs \\ []) do
    insert(
      :provider_calendar_event,
      Keyword.merge(
        [
          calendar_integration: integration,
          uid: uid,
          summary: "Busy",
          provider: integration.provider,
          provider_event_id: "pid-#{uid}",
          all_day: false,
          start_at: ~U[2027-03-02 09:00:00Z],
          end_at: ~U[2027-03-02 09:30:00Z]
        ],
        attrs
      )
    )
  end

  describe "orphans_for_user/1" do
    test "a placeholder whose mapping row is gone is reported", %{
      user: user,
      target: target,
      link: link
    } do
      # The state the scan exists for: the placeholder reached the provider and
      # came back through the target's own sync, but nothing records where it is.
      uid = Engine.target_uid_for(link.id, "source-uid-1")
      cached(target, uid)

      assert [orphan] = OrphanScan.orphans_for_user(user.id)

      assert orphan.uid == uid
      assert orphan.target_integration_id == target.id
      assert orphan.provider_event_id == "pid-#{uid}"
    end

    test "a placeholder its mapping row still claims is not an orphan", %{
      user: user,
      target: target,
      link: link
    } do
      uid = Engine.target_uid_for(link.id, "source-uid-1")
      cached(target, uid)
      mirror_for_link(link, source_uid: "source-uid-1", target_uid: uid)

      assert [] == OrphanScan.orphans_for_user(user.id)
    end

    # Google is the case a prefix scan cannot reach. It hashes the uid we hand
    # it — `tymeslot-mirror-…` contains a hyphen, so it never takes the
    # base32hex fast path — files the event under that hash, and the next
    # inbound sync caches `{hash}@google.com`. Our prefix is nowhere in it and
    # the hash does not reverse, so the identity has to be derived forward from
    # the link and the source instead.
    test "a Google placeholder whose row is gone is found by derivation", %{
      user: user,
      source: source,
      target: target,
      link: link
    } do
      cached(source, "source-uid-1", summary: "Board meeting")

      google_id =
        link.id
        |> Engine.target_uid_for("source-uid-1")
        |> EventMapper.uuid_to_google_event_id()

      # Cached exactly as Google's own normaliser would: `iCalUID || id`.
      cached(target, google_id <> "@google.com", provider_event_id: google_id)

      assert [orphan] = OrphanScan.orphans_for_user(user.id)
      assert orphan.uid == google_id <> "@google.com"
    end

    test "a Google placeholder its row still claims is not an orphan", %{
      user: user,
      source: source,
      target: target,
      link: link
    } do
      cached(source, "source-uid-1", summary: "Board meeting")

      target_uid = Engine.target_uid_for(link.id, "source-uid-1")
      google_id = EventMapper.uuid_to_google_event_id(target_uid)

      cached(target, google_id <> "@google.com", provider_event_id: google_id)

      mirror_for_link(link,
        source_uid: "source-uid-1",
        target_uid: target_uid,
        target_provider_event_id: google_id
      )

      assert [] == OrphanScan.orphans_for_user(user.id)
    end

    test "a CalDAV placeholder whose source is gone too is still found", %{
      user: user,
      target: target,
      link: link
    } do
      # Nothing to derive from — the source row is absent, so the link and uid
      # that would reproduce the identity no longer exist. The prefix scan is
      # what reaches this, and it works here because the CalDAV family stores
      # the uid it is handed. The same case on Google is not answerable, which
      # is why the prefix scan is kept alongside the derivation rather than
      # replaced by it.
      uid = Engine.target_uid_for(link.id, "long-gone-source")
      cached(target, uid)

      assert [orphan] = OrphanScan.orphans_for_user(user.id)
      assert orphan.uid == uid
    end

    test "an ordinary event on the target is never an orphan", %{
      user: user,
      target: target
    } do
      # No mirror prefix, so nothing to do with this feature.
      cached(target, "a-real-meeting@google.com", summary: "Board meeting")

      assert [] == OrphanScan.orphans_for_user(user.id)
    end

    test "a booking Tymeslot itself wrote is never an orphan", %{
      user: user,
      target: target
    } do
      # The trap this scan must not fall into. A Tymeslot booking carries the
      # same `createdBy: "tymeslot"` marker a placeholder does, and scanning by
      # that marker would report the organiser's own meetings — which a repair
      # pass would then delete.
      cached(target, "booking-uid@google.com",
        summary: "Interview",
        created_by_tymeslot: true
      )

      assert [] == OrphanScan.orphans_for_user(user.id)
    end

    test "another organiser's orphan is not reported", %{target: target, link: link} do
      stranger = insert(:user)
      uid = Engine.target_uid_for(link.id, "source-uid-1")
      cached(target, uid)

      assert [] == OrphanScan.orphans_for_user(stranger.id)
    end

    test "a user with no integrations answers an empty list" do
      assert [] == OrphanScan.orphans_for_user(insert(:user).id)
    end
  end

  describe "the cost of a scan" do
    # The scan derives three candidate identities per cached source event, and
    # originally looked each one up on its own. That is ~6,000 sequential
    # single-row queries for a link over a 2,000-event calendar — affordable
    # only while nothing but a test ever called it, and this is the schedule
    # that would have run it daily.
    #
    # The query count is asserted rather than the wall clock: a timing
    # assertion on a loaded machine measures the machine. Reverting
    # `list_by_uids/2` to a lookup per candidate fails this and leaves every
    # correctness test above green, which is precisely why it is here.
    test "asks the target a bounded number of times, not once per candidate", %{
      user: user,
      source: source
    } do
      for index <- 1..40 do
        cached(source, "source-uid-#{index}", summary: "Meeting #{index}")
      end

      {_orphans, queries} = count_queries(fn -> OrphanScan.orphans_for_user(user.id) end)

      # 40 sources derive 120 identities. The per-candidate shape issued one
      # query each; the batched shape issues one for the whole link, so the
      # total stays in single digits regardless of how big the calendar is.
      assert queries < 20,
             "expected a bounded number of queries, got #{queries} for 120 derived identities"
    end

    test "batching finds exactly what a lookup per candidate found", %{
      user: user,
      source: source,
      target: target,
      link: link
    } do
      # Equivalence, stated against the identities themselves rather than
      # against the old implementation: whatever the batch matches must be the
      # same set the individual `uid ==` lookups would have matched. Two
      # placeholders among forty sources, one cached under the CalDAV identity
      # and one under Google's, so a batch that quietly dropped either form
      # would show up here.
      for index <- 1..40 do
        cached(source, "source-uid-#{index}", summary: "Meeting #{index}")
      end

      caldav_uid = Engine.target_uid_for(link.id, "source-uid-7")
      cached(target, caldav_uid)

      google_id =
        link.id
        |> Engine.target_uid_for("source-uid-23")
        |> EventMapper.uuid_to_google_event_id()

      cached(target, google_id <> "@google.com", provider_event_id: google_id)

      found = user.id |> OrphanScan.orphans_for_user() |> MapSet.new(& &1.uid)

      assert found == MapSet.new([caldav_uid, google_id <> "@google.com"])
    end
  end

  # Counts the queries the repo issues while `fun` runs, via Ecto's own
  # telemetry event. Scoped to this process so a concurrently running async test
  # cannot inflate the count.
  defp count_queries(fun) do
    test_pid = self()
    handler_id = {__MODULE__, System.unique_integer()}

    :telemetry.attach(
      handler_id,
      [:tymeslot, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == test_pid, do: send(test_pid, {handler_id, :query})
      end,
      nil
    )

    result = fun.()
    :telemetry.detach(handler_id)

    {result, drain_queries(handler_id, 0)}
  end

  defp drain_queries(handler_id, count) do
    receive do
      {^handler_id, :query} -> drain_queries(handler_id, count + 1)
    after
      0 -> count
    end
  end
end
