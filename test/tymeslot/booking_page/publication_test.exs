defmodule Tymeslot.BookingPage.PublicationTest do
  use Tymeslot.DataCase, async: true

  @moduletag :profiles

  alias Tymeslot.BookingPage.Publication
  alias Tymeslot.Profiles
  alias Tymeslot.Repo

  describe "maybe_publish/1" do
    test "does nothing for a user without a profile, and does not create one" do
      user = insert(:user)
      insert(:meeting_type, user: user, is_active: true)

      assert Publication.maybe_publish(user.id) == :ok
      assert Profiles.get_profile(user.id) == nil
    end

    # A meeting-type save publishes after its transaction commits, by which
    # point an account deletion waiting on that save may have removed the user.
    test "does nothing for a user deleted after their save committed" do
      user = insert(:user)
      insert(:meeting_type, user: user, is_active: true)
      Repo.delete!(user)

      assert Publication.maybe_publish(user.id) == :ok
      assert Profiles.get_profile(user.id) == nil
    end
  end
end
