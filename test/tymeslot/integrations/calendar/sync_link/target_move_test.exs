defmodule Tymeslot.Integrations.Calendar.SyncLink.TargetMoveTest do
  @moduledoc """
  Whether an edit re-points a link, and so whether its placeholders have to be
  torn down before the edit is saved.

  The question this module answers is asked once per link edit and answered
  wrongly in two opposite ways, each with its own cost. Saying "moved" when
  nothing moved tears down every placeholder and rebuilds it, so the organiser
  watches their busy blocks vanish and reappear on a save that changed a label.
  Saying "unchanged" when the target moved strands every placeholder on the old
  calendar, with the mapping rows re-pointed away from them.

  The tests are therefore written in pairs — a field that must trigger and a
  field that must not — because a version that always answered `true` and a
  version that always answered `false` each pass half a suite.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :sync_links

  import Tymeslot.Factory
  import Tymeslot.SyncLinkTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema
  alias Tymeslot.Integrations.Calendar.SyncLink.TargetMove

  describe "repoint?/2 — the fields that invalidate existing placeholders" do
    setup do: linked_pair()

    test "a new target integration is a move", %{user: user, link: link} do
      elsewhere = insert(:calendar_integration, user: user, provider: "google")

      assert TargetMove.repoint?(
               link,
               CalendarSyncLinkSchema.changeset(link, %{target_integration_id: elsewhere.id})
             )
    end

    test "a new source integration is a move", %{user: user, link: link} do
      elsewhere = insert(:calendar_integration, user: user, provider: "google")

      assert TargetMove.repoint?(
               link,
               CalendarSyncLinkSchema.changeset(link, %{source_integration_id: elsewhere.id})
             )
    end

    test "a new target calendar on the same integration is a move", %{link: link} do
      # The placeholders live on a calendar, not on an integration: moving
      # between two calendars of one account leaves them exactly as stranded.
      assert TargetMove.repoint?(
               link,
               CalendarSyncLinkSchema.changeset(link, %{target_calendar_id: "work@example.com"})
             )
    end
  end

  describe "repoint?/2 — the edits that must leave placeholders alone" do
    setup do: linked_pair()

    test "a presentation change is not a move", %{link: link} do
      refute TargetMove.repoint?(
               link,
               CalendarSyncLinkSchema.changeset(link, %{
                 privacy_tier: "generic_label",
                 generic_label: "Reserved"
               })
             )
    end

    test "pausing is not a move", %{link: link} do
      refute TargetMove.repoint?(link, CalendarSyncLinkSchema.changeset(link, %{enabled: false}))
    end

    test "an empty edit is not a move", %{link: link} do
      refute TargetMove.repoint?(link, CalendarSyncLinkSchema.changeset(link, %{}))
    end

    test "re-submitting the values already stored is not a move", %{
      source: source,
      target: target,
      link: link
    } do
      # The dashboard re-submits every rendered field on every save. Comparing
      # submitted attributes against the row would still read this as unchanged;
      # the CalDAV case below is the one that separates the two approaches.
      refute TargetMove.repoint?(
               link,
               CalendarSyncLinkSchema.changeset(link, %{
                 source_integration_id: source.id,
                 target_integration_id: target.id,
                 target_calendar_id: link.target_calendar_id
               })
             )
    end
  end

  describe "repoint?/2 — the CalDAV normalisation this module must not duplicate" do
    # The failure the moduledoc records. `clear_calendar_id_when_target_cannot_choose/1`
    # nulls `target_calendar_id` for a CalDAV target, which ignores it and always
    # writes to the primary path. A form faithfully re-submitting the id it was
    # handed therefore offers `"personal"` against a stored `nil` — and comparing
    # the raw attributes reads that as a move on *every* save, tearing the
    # placeholders down and rebuilding them each time the link is edited.
    #
    # Comparing `apply_changes/1` sees the value as it will actually be stored,
    # which the changeset has already nulled. That is why this module holds no
    # copy of the CalDAV rule: one copy cannot drift from itself.
    setup do
      user = insert(:user)
      source = insert(:calendar_integration, user: user, provider: "google")
      target = insert(:calendar_integration, user: user, provider: "caldav")

      link =
        insert(:calendar_sync_link,
          user_id: user.id,
          source_integration_id: source.id,
          target_integration_id: target.id,
          target_calendar_id: nil
        )

      %{user: user, source: source, target: target, link: link}
    end

    test "a calendar id offered for a CalDAV target is normalised away, not read as a move", %{
      link: link
    } do
      assert link.target_calendar_id == nil

      # `:target_provider` is virtual and supplied by the context
      # (`SyncLink.with_owned_pair/4`), not derived from the target integration
      # row. The nulling rule reads that field, so a changeset built without it
      # skips the rule entirely — see the schema's moduledoc.
      cs =
        CalendarSyncLinkSchema.changeset(link, %{
          target_calendar_id: "personal",
          target_provider: "caldav"
        })

      # The changeset nulls it, so nothing actually changes...
      assert Changeset.apply_changes(cs).target_calendar_id == nil

      # ...and the move question has to agree with that, not with the attributes.
      refute TargetMove.repoint?(link, cs)
    end

    test "without the virtual provider the rule does not fire, and the id is a move", %{
      link: link
    } do
      # The other half of the same contract, and the reason the test above must
      # name the provider explicitly: omitting it skips the normalisation rather
      # than failing, so the id survives and genuinely is a re-point. A caller
      # that forgets `:target_provider` gets a teardown it did not intend.
      cs = CalendarSyncLinkSchema.changeset(link, %{target_calendar_id: "personal"})

      assert Changeset.apply_changes(cs).target_calendar_id == "personal"
      assert TargetMove.repoint?(link, cs)
    end
  end
end
