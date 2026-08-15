defmodule Tymeslot.Integrations.Calendar.CalendarSyncLinkQueriesTest do
  @moduledoc """
  Data access for sync links: the dashboard's listing with both integrations
  preloaded, and the create/update/delete the panel drives.

  The query module is deliberately not user-scoped — authorisation lives in the
  context — so these tests pin what it does return, including the rows a
  user_id filter must exclude.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :sync_links
  @moduletag :queries

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorSchema

  setup do
    user = insert(:user)
    source = insert(:calendar_integration, user: user, provider: "google")
    target = insert(:calendar_integration, user: user, provider: "google")

    {:ok, user: user, source: source, target: target}
  end

  defp attrs(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        user_id: ctx.user.id,
        source_integration_id: ctx.source.id,
        target_integration_id: ctx.target.id,
        target_provider: "google"
      },
      overrides
    )
  end

  describe "create/1" do
    test "stores a link", ctx do
      assert {:ok, link} = CalendarSyncLinkQueries.create(attrs(ctx))

      assert link.user_id == ctx.user.id
      assert link.privacy_tier == "busy_only"
      assert link.enabled
    end

    test "returns the changeset when the target is a read-only subscription", ctx do
      ics = insert(:calendar_integration, user: ctx.user, provider: "ics_url")

      assert {:error, changeset} =
               CalendarSyncLinkQueries.create(
                 attrs(ctx, %{target_integration_id: ics.id, target_provider: "ics_url"})
               )

      refute changeset.valid?
    end
  end

  describe "list_for_user/1" do
    test "returns the user's links with both integrations preloaded", ctx do
      {:ok, _link} = CalendarSyncLinkQueries.create(attrs(ctx))

      assert [link] = CalendarSyncLinkQueries.list_for_user(ctx.user.id)

      assert link.source_integration.id == ctx.source.id
      assert link.target_integration.id == ctx.target.id
    end

    test "does not leak another organiser's links", ctx do
      {:ok, _link} = CalendarSyncLinkQueries.create(attrs(ctx))

      other = insert(:user)

      assert CalendarSyncLinkQueries.list_for_user(other.id) == []
    end

    test "returns an empty list for a user with no links", ctx do
      assert CalendarSyncLinkQueries.list_for_user(ctx.user.id) == []
    end

    test "orders oldest first so the list does not reshuffle on every edit", ctx do
      third = insert(:calendar_integration, user: ctx.user, provider: "google")

      {:ok, first} = CalendarSyncLinkQueries.create(attrs(ctx))

      {:ok, second} =
        CalendarSyncLinkQueries.create(attrs(ctx, %{target_integration_id: third.id}))

      assert ctx.user.id |> CalendarSyncLinkQueries.list_for_user() |> Enum.map(& &1.id) ==
               [first.id, second.id]
    end
  end

  describe "list_enabled_for_source/1" do
    test "returns the links mirroring out of this integration", ctx do
      {:ok, link} = CalendarSyncLinkQueries.create(attrs(ctx))

      assert [found] = CalendarSyncLinkQueries.list_enabled_for_source(ctx.source.id)
      assert found.id == link.id
    end

    test "does not return a link whose target this integration is", ctx do
      {:ok, _link} = CalendarSyncLinkQueries.create(attrs(ctx))

      assert CalendarSyncLinkQueries.list_enabled_for_source(ctx.target.id) == []
    end

    # A paused link must not produce work, and filtering it here rather than at
    # the enqueue site is what makes "paused means no writes" true at the one
    # place the sync path looks for work.
    test "excludes a paused link", ctx do
      {:ok, link} = CalendarSyncLinkQueries.create(attrs(ctx))
      {:ok, _paused} = CalendarSyncLinkQueries.update(link, %{enabled: false})

      assert CalendarSyncLinkQueries.list_enabled_for_source(ctx.source.id) == []
    end

    test "returns every link fanning out of one source", ctx do
      third = insert(:calendar_integration, user: ctx.user, provider: "google")

      {:ok, first} = CalendarSyncLinkQueries.create(attrs(ctx))

      {:ok, second} =
        CalendarSyncLinkQueries.create(attrs(ctx, %{target_integration_id: third.id}))

      assert ctx.source.id
             |> CalendarSyncLinkQueries.list_enabled_for_source()
             |> Enum.map(& &1.id) == [first.id, second.id]
    end

    test "returns an empty list for an integration that is nobody's source", ctx do
      assert CalendarSyncLinkQueries.list_enabled_for_source(ctx.source.id) == []
    end

    test "answers an id that is not an integer without raising" do
      assert CalendarSyncLinkQueries.list_enabled_for_source("7") == []
    end
  end

  describe "get/1" do
    test "returns the link with both integrations preloaded", ctx do
      {:ok, link} = CalendarSyncLinkQueries.create(attrs(ctx))

      assert {:ok, found} = CalendarSyncLinkQueries.get(link.id)

      assert found.id == link.id
      assert found.source_integration.id == ctx.source.id
      assert found.target_integration.id == ctx.target.id
    end

    test "returns not_found for an id that does not exist", _ctx do
      assert CalendarSyncLinkQueries.get(0) == {:error, :not_found}
    end

    test "returns not_found rather than raising for a non-integer id", _ctx do
      assert CalendarSyncLinkQueries.get(nil) == {:error, :not_found}
    end
  end

  describe "update/2" do
    test "changes the privacy tier", ctx do
      {:ok, link} = CalendarSyncLinkQueries.create(attrs(ctx))

      assert {:ok, updated} =
               CalendarSyncLinkQueries.update(link, %{
                 privacy_tier: "generic_label",
                 generic_label: "Busy elsewhere"
               })

      assert updated.privacy_tier == "generic_label"
      assert updated.generic_label == "Busy elsewhere"
    end

    test "pauses a link without deleting it", ctx do
      {:ok, link} = CalendarSyncLinkQueries.create(attrs(ctx))

      assert {:ok, %{enabled: false}} = CalendarSyncLinkQueries.update(link, %{enabled: false})
      assert {:ok, _still_there} = CalendarSyncLinkQueries.get(link.id)
    end

    test "rejects a colour outside the palette", ctx do
      {:ok, link} = CalendarSyncLinkQueries.create(attrs(ctx))

      assert {:error, changeset} =
               CalendarSyncLinkQueries.update(link, %{mirror_colour: "chartreuse"})

      assert "is not a palette colour" in errors_on(changeset).mirror_colour
    end
  end

  describe "delete/1" do
    test "removes the link", ctx do
      {:ok, link} = CalendarSyncLinkQueries.create(attrs(ctx))

      assert {:ok, _deleted} = CalendarSyncLinkQueries.delete(link)

      assert CalendarSyncLinkQueries.get(link.id) == {:error, :not_found}
    end

    test "takes the link's mirrors with it", ctx do
      {:ok, link} = CalendarSyncLinkQueries.create(attrs(ctx))
      mirror = mirror_for_link(link)

      {:ok, _deleted} = CalendarSyncLinkQueries.delete(link)

      refute Repo.get(CalendarSyncMirrorSchema, mirror.id)
    end
  end

  describe "change/2" do
    test "returns a changeset the form can render", ctx do
      assert %Ecto.Changeset{} =
               changeset = CalendarSyncLinkQueries.change(%CalendarSyncLinkSchema{}, attrs(ctx))

      assert changeset.valid?
    end
  end
end
