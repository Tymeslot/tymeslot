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

  @moduletag :calendar
  @moduletag :sync_links
  @moduletag :integrations

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.SyncLink

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

  describe "toggle_enabled/3" do
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
  end

  describe "delete_link/2" do
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
  end
end
