defmodule Tymeslot.Integrations.Calendar.SyncLinkTest do
  @moduledoc """
  The sync-link context, and the two things only it can do: verify the acting
  organiser owns *both* ends of a link, and hand the target's provider to the
  changeset so the read-only-target and CalDAV rules fire at all.

  A link names two integrations, so both are forgeable. Each write is exercised
  with an id belonging to another organiser in each position, and the assertion
  is not only the `{:error, :not_found}` but that no row moved.
  """
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :sync_links
  @moduletag :integrations

  import Mox
  import Ecto.Query, only: [from: 2]
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorSchema
  alias Tymeslot.Integrations.Calendar.SyncLink
  alias Tymeslot.Repo
  alias Tymeslot.Workers.SyncLinkReconcileWorker
  alias Tymeslot.Workers.SyncLinkWriteBackWorker

  setup :verify_on_exit!

  setup do
    user = insert(:user)
    source = insert(:calendar_integration, user: user, provider: "google")
    target = insert(:calendar_integration, user: user, provider: "outlook")

    {:ok, user: user, source: source, target: target}
  end

  defp attrs(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        "source_integration_id" => ctx.source.id,
        "target_integration_id" => ctx.target.id
      },
      overrides
    )
  end

  describe "create_link/2" do
    test "stores a link between two calendars the organiser owns", ctx do
      assert {:ok, link} = SyncLink.create_link(ctx.user.id, attrs(ctx))

      assert link.user_id == ctx.user.id
      assert link.source_integration_id == ctx.source.id
      assert link.target_integration_id == ctx.target.id
      assert link.privacy_tier == "busy_only"
      assert link.enabled
    end

    test "keeps the chosen target calendar for a provider that honours one", ctx do
      assert {:ok, link} =
               SyncLink.create_link(
                 ctx.user.id,
                 attrs(ctx, %{"target_calendar_id" => "work@outlook.com"})
               )

      assert link.target_calendar_id == "work@outlook.com"
    end

    test "refuses a source belonging to another organiser and writes nothing", ctx do
      stranger = insert(:calendar_integration, provider: "google")

      assert {:error, :not_found} =
               SyncLink.create_link(
                 ctx.user.id,
                 attrs(ctx, %{"source_integration_id" => stranger.id})
               )

      assert SyncLink.list_links(ctx.user.id) == []
    end

    test "refuses a target belonging to another organiser and writes nothing", ctx do
      stranger = insert(:calendar_integration, provider: "google")

      assert {:error, :not_found} =
               SyncLink.create_link(
                 ctx.user.id,
                 attrs(ctx, %{"target_integration_id" => stranger.id})
               )

      assert SyncLink.list_links(ctx.user.id) == []
    end

    test "refuses a read-only subscription as the target", ctx do
      ics = insert(:calendar_integration, user: ctx.user, provider: "ics_url")

      assert {:error, changeset} =
               SyncLink.create_link(
                 ctx.user.id,
                 attrs(ctx, %{"target_integration_id" => ics.id})
               )

      refute changeset.valid?
      assert errors_on(changeset).target_integration_id != []
      assert SyncLink.list_links(ctx.user.id) == []
    end

    test "clears the target calendar for a CalDAV target, which ignores it", ctx do
      caldav = insert(:calendar_integration, user: ctx.user, provider: "nextcloud")

      assert {:ok, link} =
               SyncLink.create_link(
                 ctx.user.id,
                 attrs(ctx, %{
                   "target_integration_id" => caldav.id,
                   "target_calendar_id" => "personal"
                 })
               )

      assert is_nil(link.target_calendar_id)
    end

    test "refuses a link from a calendar onto itself", ctx do
      assert {:error, changeset} =
               SyncLink.create_link(
                 ctx.user.id,
                 attrs(ctx, %{"target_integration_id" => ctx.source.id})
               )

      refute changeset.valid?
      assert SyncLink.list_links(ctx.user.id) == []
    end

    test "refuses an integration id that is not an integer", ctx do
      assert {:error, :not_found} =
               SyncLink.create_link(
                 ctx.user.id,
                 attrs(ctx, %{"target_integration_id" => "not-an-id"})
               )
    end
  end

  describe "list_links/1" do
    test "returns only the acting organiser's links, with both ends preloaded", ctx do
      {:ok, _link} = SyncLink.create_link(ctx.user.id, attrs(ctx))

      stranger = insert(:user)
      stranger_source = insert(:calendar_integration, user: stranger, provider: "google")
      stranger_target = insert(:calendar_integration, user: stranger, provider: "google")

      {:ok, _other} =
        SyncLink.create_link(stranger.id, %{
          "source_integration_id" => stranger_source.id,
          "target_integration_id" => stranger_target.id
        })

      assert [link] = SyncLink.list_links(ctx.user.id)
      assert link.source_integration.id == ctx.source.id
      assert link.target_integration.id == ctx.target.id
    end
  end

  describe "update_link/3" do
    setup ctx do
      {:ok, link} = SyncLink.create_link(ctx.user.id, attrs(ctx))
      {:ok, link: link}
    end

    test "changes the privacy tier", %{user: user, link: link} do
      assert {:ok, updated} =
               SyncLink.update_link(user.id, link.id, %{
                 "privacy_tier" => "generic_label",
                 "generic_label" => "Busy elsewhere"
               })

      assert updated.privacy_tier == "generic_label"
      assert updated.generic_label == "Busy elsewhere"
    end

    test "refuses a link belonging to another organiser and leaves it alone", %{link: link} do
      stranger = insert(:user)

      assert {:error, :not_found} =
               SyncLink.update_link(stranger.id, link.id, %{"privacy_tier" => "full_passthrough"})

      assert [unchanged] = SyncLink.list_links(link.user_id)
      assert unchanged.privacy_tier == "busy_only"
    end

    test "re-applies the CalDAV rule when the target moves to a CalDAV calendar",
         %{link: link} = ctx do
      caldav = insert(:calendar_integration, user: ctx.user, provider: "baikal")

      assert {:ok, updated} =
               SyncLink.update_link(ctx.user.id, link.id, %{
                 "target_integration_id" => caldav.id,
                 "target_calendar_id" => "personal"
               })

      assert is_nil(updated.target_calendar_id)
    end

    test "refuses moving the target onto a read-only subscription", %{link: link} = ctx do
      ics = insert(:calendar_integration, user: ctx.user, provider: "ics_url")

      assert {:error, changeset} =
               SyncLink.update_link(ctx.user.id, link.id, %{
                 "target_integration_id" => ics.id
               })

      refute changeset.valid?
    end

    test "refuses moving the target onto another organiser's calendar", %{link: link} = ctx do
      stranger = insert(:calendar_integration, provider: "google")

      assert {:error, :not_found} =
               SyncLink.update_link(ctx.user.id, link.id, %{
                 "target_integration_id" => stranger.id
               })

      assert [unchanged] = SyncLink.list_links(ctx.user.id)
      assert unchanged.target_integration_id == ctx.target.id
    end

    test "answers not_found for a link id that does not exist", %{user: user} do
      assert {:error, :not_found} = SyncLink.update_link(user.id, 0, %{})
    end
  end

  describe "update_link/3 when the target moves" do
    setup ctx do
      {:ok, link} = SyncLink.create_link(ctx.user.id, attrs(ctx))
      {:ok, link: link}
    end

    test "withdraws the placeholders from the OLD target before re-pointing", ctx do
      %{link: link} = ctx
      elsewhere = insert(:calendar_integration, user: ctx.user, provider: "google")
      mirror = mirror_for_link(link, source_uid: "src-1", target_uid: "mirror-uid-1")
      test_pid = self()

      expect(Tymeslot.CalendarMock, :delete_event, fn uid, {integration_id, user_id}, _opts ->
        # The withdrawal must be addressed at the target as it stands *now*, not
        # at the one the attributes are asking for: the busy block is on the old
        # calendar, and a delete aimed at the new one draws a 404 read as
        # "already gone".
        send(test_pid, {:withdrawn, uid, integration_id, user_id})
        :ok
      end)

      assert {:ok, updated} =
               SyncLink.update_link(ctx.user.id, link.id, %{
                 "target_integration_id" => elsewhere.id
               })

      assert_received {:withdrawn, "mirror-uid-1", integration_id, user_id}
      assert integration_id == ctx.target.id
      assert user_id == ctx.user.id

      assert updated.target_integration_id == elsewhere.id
      refute Repo.get(CalendarSyncMirrorSchema, mirror.id)
    end

    test "addresses the OLD calendar when only the target calendar moves", ctx do
      %{link: link} = ctx

      {:ok, link} =
        SyncLink.update_link(ctx.user.id, link.id, %{
          "target_calendar_id" => "written-to@outlook.com"
        })

      mirror =
        mirror_for_link(link,
          source_uid: "src-1",
          target_uid: "mirror-uid-1",
          target_calendar_id: "written-to@outlook.com"
        )

      test_pid = self()

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, opts ->
        send(test_pid, {:calendar_id, opts[:calendar_id]})
        :ok
      end)

      assert {:ok, updated} =
               SyncLink.update_link(ctx.user.id, link.id, %{
                 "target_calendar_id" => "moved-to@outlook.com"
               })

      assert_received {:calendar_id, "written-to@outlook.com"}
      assert updated.target_calendar_id == "moved-to@outlook.com"
      refute Repo.get(CalendarSyncMirrorSchema, mirror.id)
    end

    test "counts a target calendar first being chosen as a move", ctx do
      %{link: link} = ctx
      mirror = mirror_for_link(link, source_uid: "src-1", target_uid: "mirror-uid-1")

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)

      assert {:ok, updated} =
               SyncLink.update_link(ctx.user.id, link.id, %{
                 "target_calendar_id" => "team@outlook.com"
               })

      assert updated.target_calendar_id == "team@outlook.com"
      refute Repo.get(CalendarSyncMirrorSchema, mirror.id)
    end

    test "withdraws when the SOURCE moves, since every mapping names its uids", ctx do
      %{link: link} = ctx
      other_source = insert(:calendar_integration, user: ctx.user, provider: "google")
      mirror = mirror_for_link(link, source_uid: "src-1", target_uid: "mirror-uid-1")

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)

      assert {:ok, updated} =
               SyncLink.update_link(ctx.user.id, link.id, %{
                 "source_integration_id" => other_source.id
               })

      assert updated.source_integration_id == other_source.id
      refute Repo.get(CalendarSyncMirrorSchema, mirror.id)
    end

    test "leaves the link on its old target when the withdrawal fails", ctx do
      %{link: link} = ctx
      elsewhere = insert(:calendar_integration, user: ctx.user, provider: "google")
      mirror = mirror_for_link(link, source_uid: "src-1", target_uid: "mirror-uid-1")

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
        {:error, :service_unavailable}
      end)

      assert {:error, :service_unavailable} =
               SyncLink.update_link(ctx.user.id, link.id, %{
                 "target_integration_id" => elsewhere.id
               })

      # Re-pointing anyway is precisely the orphan this exists to prevent: the
      # busy block stays on the old calendar and the row that names it now
      # points somewhere it never was.
      assert [survivor] = SyncLink.list_links(ctx.user.id)
      assert survivor.target_integration_id == ctx.target.id
      assert %{state: "pending_delete"} = Repo.get(CalendarSyncMirrorSchema, mirror.id)
    end

    test "keeps the link enabled after a move, so the sweep refills the new target", ctx do
      %{link: link} = ctx
      elsewhere = insert(:calendar_integration, user: ctx.user, provider: "google")
      mirror_for_link(link, source_uid: "src-1", target_uid: "mirror-uid-1")

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)

      assert {:ok, updated} =
               SyncLink.update_link(ctx.user.id, link.id, %{
                 "target_integration_id" => elsewhere.id
               })

      # Teardown pauses the link on its way through. A move that left it paused
      # would drop it out of `list_due_for_reconcile/1` — which skips a disabled
      # link holding no `pending_delete` rows — so the new target would stay
      # empty for as long as the organiser did not notice.
      assert updated.enabled

      # Read back rather than trusting the returned struct. `put_change/3` in
      # place of `force_change/3` records no change — the changeset's data
      # still holds the pre-teardown value — so the struct comes back enabled
      # while the row stays disabled, which is the whole failure this guards.
      assert %{enabled: true} = Repo.get(CalendarSyncLinkSchema, updated.id)
    end

    test "a paused link stays paused across a move", ctx do
      %{link: link} = ctx
      elsewhere = insert(:calendar_integration, user: ctx.user, provider: "google")
      {:ok, link} = SyncLink.toggle_enabled(ctx.user.id, link.id, false)
      mirror_for_link(link, source_uid: "src-1", target_uid: "mirror-uid-1")

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)

      assert {:ok, updated} =
               SyncLink.update_link(ctx.user.id, link.id, %{
                 "target_integration_id" => elsewhere.id
               })

      refute updated.enabled

      assert %{enabled: false} = Repo.get(CalendarSyncLinkSchema, updated.id)
    end
  end

  describe "update_link/3 when the target does not move" do
    setup ctx do
      {:ok, link} = SyncLink.create_link(ctx.user.id, attrs(ctx))
      {:ok, link: link}
    end

    # No `expect` anywhere in these: `verify_on_exit!` turns any provider call
    # into a failure, which is the whole assertion. A tier change destroying
    # every placeholder the link has written is the regression this guards.
    test "a privacy tier change tears down nothing", %{user: user, link: link} do
      mirror = mirror_for_link(link, source_uid: "src-1", target_uid: "mirror-uid-1")

      assert {:ok, updated} =
               SyncLink.update_link(user.id, link.id, %{
                 "privacy_tier" => "generic_label",
                 "generic_label" => "Busy elsewhere"
               })

      assert updated.privacy_tier == "generic_label"
      assert %{state: "active"} = Repo.get(CalendarSyncMirrorSchema, mirror.id)
    end

    test "re-submitting the same target is not a move", ctx do
      %{link: link} = ctx
      mirror = mirror_for_link(link, source_uid: "src-1", target_uid: "mirror-uid-1")

      assert {:ok, _updated} =
               SyncLink.update_link(ctx.user.id, link.id, %{
                 "source_integration_id" => ctx.source.id,
                 "target_integration_id" => ctx.target.id,
                 "mirror_colour" => "sage"
               })

      assert %{state: "active"} = Repo.get(CalendarSyncMirrorSchema, mirror.id)
    end

    test "a CalDAV target normalised to no calendar is not read as a re-point", ctx do
      caldav = insert(:calendar_integration, user: ctx.user, provider: "baikal")

      {:ok, link} =
        SyncLink.create_link(
          ctx.user.id,
          attrs(ctx, %{"target_integration_id" => caldav.id})
        )

      # The changeset nulls a calendar id a CalDAV target cannot honour, so the
      # stored value is already nil. A form re-submitting the id it was given
      # would otherwise read as nil → "personal" → a move, and tear down every
      # placeholder on a link nobody asked to move.
      assert is_nil(link.target_calendar_id)
      mirror = mirror_for_link(link, source_uid: "src-1", target_uid: "mirror-uid-1")

      assert {:ok, updated} =
               SyncLink.update_link(ctx.user.id, link.id, %{
                 "target_calendar_id" => "personal",
                 "privacy_tier" => "full_passthrough"
               })

      assert is_nil(updated.target_calendar_id)
      assert %{state: "active"} = Repo.get(CalendarSyncMirrorSchema, mirror.id)
    end

    test "a move rejected by the changeset withdraws nothing", %{link: link} = ctx do
      ics = insert(:calendar_integration, user: ctx.user, provider: "ics_url")
      mirror = mirror_for_link(link, source_uid: "src-1", target_uid: "mirror-uid-1")

      assert {:error, changeset} =
               SyncLink.update_link(ctx.user.id, link.id, %{
                 "target_integration_id" => ics.id
               })

      refute changeset.valid?

      # The link never moves, so its placeholders are exactly where the mapping
      # says they are. Withdrawing them for a save that was refused would empty
      # the target for nothing.
      assert %{state: "active"} = Repo.get(CalendarSyncMirrorSchema, mirror.id)
    end
  end

  describe "toggle_enabled/3" do
    test "pauses a link whose stored attributes no longer satisfy the changeset", ctx do
      # A row written before `generic_label` became required at its tier — the
      # panel has a dedicated label for exactly these, so the feature is
      # designed for their existence. Routing the pause through the full
      # changeset made it fail on a field the write never touches, and the
      # component discarded the refusal, so the button did nothing and said
      # nothing. Pausing has to be about `enabled` and nothing else: it is the
      # control an organiser reaches for precisely when a link is misbehaving.
      {:ok, link} = SyncLink.create_link(ctx.user.id, attrs(ctx))

      {1, _no_returning} =
        Repo.update_all(
          from(l in CalendarSyncLinkSchema, where: l.id == ^link.id),
          set: [privacy_tier: "generic_label", generic_label: nil]
        )

      assert {:ok, paused} = SyncLink.toggle_enabled(ctx.user.id, link.id, false)
      refute paused.enabled
    end

    test "pauses and resumes a link", ctx do
      {:ok, link} = SyncLink.create_link(ctx.user.id, attrs(ctx))

      assert {:ok, %{enabled: false}} = SyncLink.toggle_enabled(ctx.user.id, link.id, false)
      assert {:ok, %{enabled: true}} = SyncLink.toggle_enabled(ctx.user.id, link.id, true)
    end

    test "refuses another organiser's link", ctx do
      {:ok, link} = SyncLink.create_link(ctx.user.id, attrs(ctx))
      stranger = insert(:user)

      assert {:error, :not_found} = SyncLink.toggle_enabled(stranger.id, link.id, false)

      assert [unchanged] = SyncLink.list_links(ctx.user.id)
      assert unchanged.enabled
    end

    # Pausing leaves the placeholders in place, which the docstring says. What
    # *resuming* does is the half nothing stated, and it is worth stating: a
    # resume enqueues nothing at all. No write-back, no reconcile, no provider
    # call — the row's `enabled` flips and that is the whole operation.
    #
    # The catch-up is therefore entirely the reconcile sweep's, and it arrives
    # on the sweep's own schedule rather than on the organiser's click. A source
    # edited while the link was paused goes on showing its old placeholder until
    # then; a source created while it was paused has no placeholder at all until
    # then. That is the accepted design — a resume is not a request to write
    # anything *now* — but it is a delay the organiser is given no sign of, so it
    # is pinned here rather than left to be rediscovered.
    test "resuming a link enqueues nothing and reaches for no provider", ctx do
      {:ok, link} = SyncLink.create_link(ctx.user.id, attrs(ctx))
      mirror_for_link(link, source_uid: "src-1", target_uid: "mirror-uid-1")

      {:ok, _paused} = SyncLink.toggle_enabled(ctx.user.id, link.id, false)

      # No Mox expectation of any kind: `verify_on_exit!` fails this test if the
      # resume so much as reaches for the target calendar.
      assert {:ok, resumed} = SyncLink.toggle_enabled(ctx.user.id, link.id, true)
      assert resumed.enabled

      refute_enqueued(worker: SyncLinkWriteBackWorker)
      refute_enqueued(worker: SyncLinkReconcileWorker)
    end

    # What a resume additionally refuses, and what it must not, is
    # `SyncLinkResumeWritabilityTest`.
  end

  describe "delete_link/2" do
    # A link that never mirrored anything has nothing to withdraw, so this also
    # pins that the teardown reaches for no provider at all: `verify_on_exit!`
    # turns any call into a failure.
    test "removes the organiser's own link", ctx do
      {:ok, link} = SyncLink.create_link(ctx.user.id, attrs(ctx))

      assert {:ok, _deleted} = SyncLink.delete_link(ctx.user.id, link.id)
      assert SyncLink.list_links(ctx.user.id) == []
    end

    test "refuses another organiser's link and leaves the row in place", ctx do
      {:ok, link} = SyncLink.create_link(ctx.user.id, attrs(ctx))
      stranger = insert(:user)

      assert {:error, :not_found} = SyncLink.delete_link(stranger.id, link.id)
      assert [_still_there] = SyncLink.list_links(ctx.user.id)
    end

    test "withdraws every placeholder from the provider before dropping the row", ctx do
      {:ok, link} = SyncLink.create_link(ctx.user.id, attrs(ctx))
      mirror = mirror_for_link(link, source_uid: "src-1", target_uid: "mirror-uid-1")
      test_pid = self()

      expect(Tymeslot.CalendarMock, :delete_event, fn uid, {integration_id, user_id}, _opts ->
        # The link and its mapping row must both still exist while the provider
        # is asked: the row is what carries the uid being deleted.
        assert Repo.get(CalendarSyncMirrorSchema, mirror.id)
        send(test_pid, {:withdrawn, uid, integration_id, user_id})
        :ok
      end)

      assert {:ok, _deleted} = SyncLink.delete_link(ctx.user.id, link.id)

      assert_received {:withdrawn, "mirror-uid-1", target_id, user_id}
      assert target_id == ctx.target.id
      assert user_id == ctx.user.id

      assert SyncLink.list_links(ctx.user.id) == []
      refute Repo.get(CalendarSyncMirrorSchema, mirror.id)
    end

    test "keeps the link when a placeholder cannot be withdrawn", ctx do
      {:ok, link} = SyncLink.create_link(ctx.user.id, attrs(ctx))
      mirror = mirror_for_link(link, source_uid: "src-1", target_uid: "mirror-uid-1")

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
        {:error, :service_unavailable}
      end)

      assert {:error, :service_unavailable} = SyncLink.delete_link(ctx.user.id, link.id)

      # Dropping the link would cascade the mapping away and strand the busy
      # block on the target with nothing naming it.
      assert [survivor] = SyncLink.list_links(ctx.user.id)
      refute survivor.enabled
      assert %{state: "pending_delete"} = Repo.get(CalendarSyncMirrorSchema, mirror.id)
    end
  end
end
