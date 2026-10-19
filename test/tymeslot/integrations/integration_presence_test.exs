defmodule Tymeslot.Integrations.IntegrationPresenceTest do
  use Tymeslot.DataCase, async: true

  @moduletag :integrations

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Security.Encryption

  defp ics(user, attrs \\ []) do
    insert(
      :calendar_integration,
      Keyword.merge(
        [
          user: user,
          provider: "ics_url",
          base_url: "https://feeds.example.com",
          username_encrypted: nil,
          password_encrypted: nil,
          subscription_url_encrypted: Encryption.encrypt("https://feeds.example.com/feed.ics")
        ],
        attrs
      )
    )
  end

  describe "Calendar.has_bookable_integration?/1" do
    test "is true for an active writable calendar" do
      user = insert(:user)
      insert(:calendar_integration, user: user, provider: "caldav")

      assert Calendar.has_bookable_integration?(user.id)
    end

    test "ignores an inactive writable calendar beside an active read-only feed" do
      user = insert(:user)
      insert(:calendar_integration, user: user, provider: "caldav", is_active: false)
      ics(user)

      refute Calendar.has_bookable_integration?(user.id)
    end

    test "ignores another user's calendars" do
      user = insert(:user)
      insert(:calendar_integration, provider: "caldav")

      refute Calendar.has_bookable_integration?(user.id)
    end
  end

  describe "Video.has_active_integration?/1" do
    test "is true for an active integration and false once it is switched off" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, is_active: true)
      assert Video.has_active_integration?(user.id)

      Repo.update!(Changeset.change(integration, is_active: false))
      refute Video.has_active_integration?(user.id)
    end

    test "ignores a disconnected integration even if still flagged active" do
      user = insert(:user)

      insert(:video_integration,
        user: user,
        is_active: true,
        deleted_at: DateTime.utc_now(:second)
      )

      refute Video.has_active_integration?(user.id)
    end

    test "ignores another user's integrations" do
      user = insert(:user)
      insert(:video_integration, is_active: true)

      refute Video.has_active_integration?(user.id)
    end
  end
end
