defmodule Tymeslot.AnnouncementsTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.Announcements
  alias Tymeslot.Announcements.AnnouncementQueries
  alias Tymeslot.Announcements.UserSeenAnnouncementSchema
  alias Tymeslot.AnnouncementsTestCatalog
  alias Tymeslot.Repo

  describe "AnnouncementQueries.seen_keys_for/1" do
    test "returns the keys the user has marked seen" do
      user = insert(:user)
      other_user = insert(:user)

      Repo.insert!(%UserSeenAnnouncementSchema{
        user_id: user.id,
        announcement_key: "feature_a",
        seen_at: DateTime.utc_now(:second)
      })

      Repo.insert!(%UserSeenAnnouncementSchema{
        user_id: other_user.id,
        announcement_key: "feature_b",
        seen_at: DateTime.utc_now(:second)
      })

      assert AnnouncementQueries.seen_keys_for(user.id) == ["feature_a"]
    end
  end

  describe "AnnouncementQueries.mark_seen!/2" do
    test "writes a row" do
      user = insert(:user)

      assert :ok = AnnouncementQueries.mark_seen!(user.id, "feature_a")

      assert AnnouncementQueries.seen_keys_for(user.id) == ["feature_a"]
    end

    test "is idempotent — calling twice does not raise and does not duplicate" do
      user = insert(:user)

      assert :ok = AnnouncementQueries.mark_seen!(user.id, "feature_a")
      assert :ok = AnnouncementQueries.mark_seen!(user.id, "feature_a")

      assert AnnouncementQueries.seen_keys_for(user.id) == ["feature_a"]
    end

    test "raises when the user does not exist (FK violation)" do
      assert_raise Ecto.InvalidChangesetError, fn ->
        AnnouncementQueries.mark_seen!(-1, "feature_a")
      end
    end
  end

  describe "FK cascade on user delete" do
    test "deleting a user removes their seen records" do
      user = insert(:user)
      AnnouncementQueries.mark_seen!(user.id, "feature_a")
      assert AnnouncementQueries.seen_keys_for(user.id) == ["feature_a"]

      Repo.delete!(user)

      assert AnnouncementQueries.seen_keys_for(user.id) == []
    end
  end

  describe "Announcements.mark_seen!/2" do
    test "marks the announcement as seen" do
      user = insert(:user)

      assert :ok = Announcements.mark_seen!(user, "test_alpha")

      assert AnnouncementQueries.seen_keys_for(user.id) == ["test_alpha"]
    end

    test "is idempotent" do
      user = insert(:user)

      assert :ok = Announcements.mark_seen!(user, "test_alpha")
      assert :ok = Announcements.mark_seen!(user, "test_alpha")

      assert AnnouncementQueries.seen_keys_for(user.id) == ["test_alpha"]
    end
  end

  describe "Announcements.list_for/1" do
    setup do
      previous = Application.get_env(:tymeslot, :announcement_catalogs, [])

      Application.put_env(:tymeslot, :announcement_catalogs, [
        AnnouncementsTestCatalog
      ])

      on_exit(fn -> Application.put_env(:tymeslot, :announcement_catalogs, previous) end)

      :ok
    end

    test "returns all unseen announcements published after the user signed up" do
      user = insert(:user, inserted_at: ~N[2025-12-01 00:00:00])

      assert [%{key: "test_alpha"}, %{key: "test_beta"}] =
               Announcements.list_for(user)
    end

    test "filters out announcements the user has already seen" do
      user = insert(:user, inserted_at: ~N[2025-12-01 00:00:00])
      Announcements.mark_seen!(user, "test_alpha")

      assert [%{key: "test_beta"}] = Announcements.list_for(user)
    end

    test "filters out announcements published before the user signed up" do
      # User signed up after `test_alpha` (2026-01-01) but before `test_beta` (2026-02-01).
      user = insert(:user, inserted_at: ~N[2026-01-15 00:00:00])

      assert [%{key: "test_beta"}] = Announcements.list_for(user)
    end

    test "orders by published_at ascending" do
      user = insert(:user, inserted_at: ~N[2025-12-01 00:00:00])

      result = Announcements.list_for(user)

      published_ats = Enum.map(result, & &1.published_at)
      assert published_ats == Enum.sort(published_ats, DateTime)
    end

    test "combines entries from multiple registered catalogs" do
      defmodule SecondTestCatalog do
        @moduledoc false
        alias Tymeslot.Announcements.Announcement

        @spec list() :: [Announcement.t()]
        def list do
          [
            %Announcement{
              key: "test_gamma",
              title: "Gamma",
              body: "Third",
              published_at: ~U[2026-03-01 00:00:00Z]
            }
          ]
        end
      end

      Application.put_env(:tymeslot, :announcement_catalogs, [
        AnnouncementsTestCatalog,
        __MODULE__.SecondTestCatalog
      ])

      user = insert(:user, inserted_at: ~N[2025-12-01 00:00:00])
      keys = user |> Announcements.list_for() |> Enum.map(& &1.key)

      assert keys == ["test_alpha", "test_beta", "test_gamma"]
    end
  end
end
