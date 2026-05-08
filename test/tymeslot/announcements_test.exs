defmodule Tymeslot.AnnouncementsTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.Announcements.AnnouncementQueries
  alias Tymeslot.Announcements.UserSeenAnnouncementSchema
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
end
