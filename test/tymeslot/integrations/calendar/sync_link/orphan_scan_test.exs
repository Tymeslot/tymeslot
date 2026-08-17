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
end
