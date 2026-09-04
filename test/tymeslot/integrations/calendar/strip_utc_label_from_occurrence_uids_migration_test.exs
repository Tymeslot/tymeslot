defmodule Tymeslot.Integrations.Calendar.StripUtcLabelFromOccurrenceUidsMigrationTest do
  @moduledoc """
  Covers the migration that drops the trailing `Z` from every stored recurring
  occurrence UID, keeping the cache and the per-event colour overrides addressable
  by the UID `ICalNormaliser.build_uid/1` now emits.

  What matters is the pair of boundaries. Rewrite too little and the occurrence
  is orphaned: the cache row looks deleted on the next full fetch and the colour
  override points at a UID nothing produces again. Rewrite too much and a
  perfectly good non-occurrence UID (an all-day occurrence, a Google instance
  iCalUID, a Tymeslot booking) is destroyed the same way. Both directions are
  asserted here, and the two tables are asserted together, because a rewrite
  that reaches only one of them re-orphans the colour choice it was meant to
  save.

  The migration is driven from `priv` (`MigrationRunner.replay!/2`, since its
  `down/0` is a deliberate no-op) so the assertions are about the SQL that
  ships rather than a pasted copy of it. See `Tymeslot.Test.MigrationRunner`.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :calendar
  @moduletag :migrations

  alias Tymeslot.Integrations.Calendar.ColourOverride
  alias Tymeslot.Repo

  alias Tymeslot.Test.MigrationRunner

  @version 20_260_904_094_944

  @old_uid "abc-123_20260904T140000Z"
  @new_uid "abc-123_20260904T140000"

  describe "up/0" do
    test "strips the UTC label from a cached occurrence UID" do
      integration = insert(:calendar_integration)
      event = insert(:provider_calendar_event, calendar_integration: integration, uid: @old_uid)

      MigrationRunner.replay!(@version)

      assert Repo.reload!(event).uid == @new_uid
    end

    test "moves the colour override with the occurrence it colours" do
      integration = insert(:calendar_integration)
      event = insert(:provider_calendar_event, calendar_integration: integration, uid: @old_uid)
      override = external_override(integration, @old_uid)

      MigrationRunner.replay!(@version)

      assert Repo.reload!(override).provider_uid == @new_uid
      assert Repo.reload!(override).provider_uid == Repo.reload!(event).uid
    end

    test "leaves every UID that is not a timed occurrence suffix untouched" do
      integration = insert(:calendar_integration)

      untouched = [
        # An ordinary non-recurring event: the provider's own opaque UID.
        "7C9F2A10-3B4D-4E55-9A21-0F1E2D3C4B5A",
        # An all-day occurrence: `%Y%m%d`, never carried a `Z` to strip.
        "abc-123_20260904",
        # A Google recurring instance: same fragment, but not at the end.
        "abc123_20260904T140000Z@google.com",
        # One of our own bookings.
        "meeting-abc@tymeslot.com",
        # Digits in the right shape but no separating underscore.
        "abc-12320260904T140000Z"
      ]

      events =
        for uid <- untouched,
            do:
              {uid, insert(:provider_calendar_event, calendar_integration: integration, uid: uid)}

      overrides = for uid <- untouched, do: {uid, external_override(integration, uid)}

      MigrationRunner.replay!(@version)

      assert Enum.reject(events, fn {uid, event} -> Repo.reload!(event).uid == uid end) == []

      assert Enum.reject(overrides, fn {uid, override} ->
               Repo.reload!(override).provider_uid == uid
             end) == []
    end

    test "leaves a booking's colour override alone: it targets a meeting, not a provider UID" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user_id: user.id)

      override =
        Repo.insert!(%ColourOverride{
          user_id: user.id,
          meeting_id: meeting.id,
          colour: "blueberry"
        })

      MigrationRunner.replay!(@version)

      reloaded = Repo.reload!(override)
      assert reloaded.meeting_id == meeting.id
      assert is_nil(reloaded.provider_uid)
    end

    test "drops the stale duplicate when a delta sync already wrote the new-format row" do
      integration = insert(:calendar_integration)
      stale = insert(:provider_calendar_event, calendar_integration: integration, uid: @old_uid)

      fresh =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          uid: @new_uid,
          summary: "The freshly synced one"
        )

      MigrationRunner.replay!(@version)

      assert is_nil(Repo.reload(stale))
      assert Repo.reload!(fresh).summary == "The freshly synced one"
    end

    test "drops the stale duplicate colour override rather than colliding on the unique index" do
      integration = insert(:calendar_integration)
      stale = external_override(integration, @old_uid, colour: "blueberry")
      fresh = external_override(integration, @new_uid, colour: "sage")

      MigrationRunner.replay!(@version)

      assert is_nil(Repo.reload(stale))
      assert Repo.reload!(fresh).colour == "sage"
    end

    test "scopes the duplicate check to one integration: a same-UID row elsewhere is not a twin" do
      integration = insert(:calendar_integration)
      other = insert(:calendar_integration)

      event = insert(:provider_calendar_event, calendar_integration: integration, uid: @old_uid)
      elsewhere = insert(:provider_calendar_event, calendar_integration: other, uid: @new_uid)

      MigrationRunner.replay!(@version)

      assert Repo.reload!(event).uid == @new_uid
      assert Repo.reload!(elsewhere).uid == @new_uid
    end
  end

  defp external_override(integration, provider_uid, opts \\ []) do
    Repo.insert!(%ColourOverride{
      user_id: integration.user_id,
      calendar_integration_id: integration.id,
      provider_uid: provider_uid,
      colour: Keyword.get(opts, :colour, "blueberry")
    })
  end
end
