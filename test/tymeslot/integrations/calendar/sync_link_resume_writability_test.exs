defmodule Tymeslot.Integrations.Calendar.SyncLinkResumeWritabilityTest do
  @moduledoc """
  The one rule a resume applies that a pause does not, and the far larger set
  neither of them applies.

  Pausing and resuming look like one operation with a boolean, and they are
  not. Pausing stops writes, so nothing it could be checked against can make it
  wrong; resuming starts them, and a target that answers `{:error, :read_only}`
  to every create — an integration reconnected as a subscription while a link
  went on pointing at it — makes those writes fail for as long as the link
  lives.

  So both directions are exercised here, and the pause half matters as much as
  the refusal. A link whose target went read-only is exactly the misbehaving
  link `CalendarSyncLinkSchema.enabled_changeset/2` was narrowed for: pausing
  is the only control an organiser has over one, and gating it on the same rule
  would leave them holding a link they can neither fix nor stop. The third test
  guards the other edge of that narrowing — a resume must not start refusing
  over a stored label or colour it never writes.

  Split from `SyncLinkTest`, which is at the line limit the analyser enforces.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :sync_links
  @moduletag :integrations

  import Ecto.Query, only: [from: 2]
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema
  alias Tymeslot.Integrations.Calendar.SyncLink
  alias Tymeslot.Repo

  setup do
    user = insert(:user)
    source = insert(:calendar_integration, user: user, provider: "google")
    target = insert(:calendar_integration, user: user, provider: "outlook")

    {:ok, link} =
      SyncLink.create_link(user.id, %{
        "source_integration_id" => source.id,
        "target_integration_id" => target.id
      })

    {:ok, user: user, source: source, target: target, link: link}
  end

  # The row keeps its id, so every link naming it goes on naming it, and only
  # the provider changes. The state cannot be reached through the context —
  # `create_link/2` refuses an ICS target outright — which is precisely why it
  # arrives at a link that already exists.
  defp reconnect_as_subscription(target) do
    {1, _no_returning} =
      Repo.update_all(
        from(i in CalendarIntegrationSchema, where: i.id == ^target.id),
        set: [provider: "ics_url"]
      )
  end

  describe "resuming a link whose target became a read-only subscription" do
    test "is refused, and leaves the link paused", ctx do
      {:ok, _paused} = SyncLink.toggle_enabled(ctx.user.id, ctx.link.id, false)

      reconnect_as_subscription(ctx.target)

      assert {:error, changeset} = SyncLink.toggle_enabled(ctx.user.id, ctx.link.id, true)
      refute changeset.valid?
      assert errors_on(changeset).target_integration_id != []

      # Refused means refused: nothing was written, so the row is still paused.
      assert [%{enabled: false}] = SyncLink.list_links(ctx.user.id)
    end

    test "the refusal names the target rather than a field the organiser did not touch", ctx do
      {:ok, _paused} = SyncLink.toggle_enabled(ctx.user.id, ctx.link.id, false)
      reconnect_as_subscription(ctx.target)

      assert {:error, changeset} = SyncLink.toggle_enabled(ctx.user.id, ctx.link.id, true)

      # The same message `create_link/2` and a re-point already answer with, so
      # the panel's existing field label completes exactly the same sentence.
      assert %{target_integration_id: [message]} = errors_on(changeset)
      assert message =~ "read-only subscription"
      assert Map.keys(errors_on(changeset)) == [:target_integration_id]
    end
  end

  describe "pausing a link whose target became a read-only subscription" do
    test "still works, because pausing a broken link is the point", ctx do
      reconnect_as_subscription(ctx.target)

      assert {:ok, paused} = SyncLink.toggle_enabled(ctx.user.id, ctx.link.id, false)
      refute paused.enabled
      assert [%{enabled: false}] = SyncLink.list_links(ctx.user.id)
    end
  end

  describe "the fields a resume does not re-validate" do
    # The other edge of the narrowing. Widening the resume to the full
    # `changeset/2` to reach the writability rule would reintroduce the failure
    # `enabled_changeset/2` exists to avoid: a control refusing over a field it
    # never writes.
    test "a stored label and colour that no longer validate do not block a resume", ctx do
      {:ok, _paused} = SyncLink.toggle_enabled(ctx.user.id, ctx.link.id, false)

      {1, _no_returning} =
        Repo.update_all(
          from(l in CalendarSyncLinkSchema, where: l.id == ^ctx.link.id),
          set: [privacy_tier: "generic_label", generic_label: nil, mirror_colour: "not-a-colour"]
        )

      assert {:ok, resumed} = SyncLink.toggle_enabled(ctx.user.id, ctx.link.id, true)
      assert resumed.enabled

      # And the fields it never touched are exactly as they were stored, rather
      # than trimmed, nulled or defaulted on the way past.
      assert resumed.privacy_tier == "generic_label"
      assert is_nil(resumed.generic_label)
      assert resumed.mirror_colour == "not-a-colour"
    end
  end
end
