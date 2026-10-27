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

  describe "Calendar.booking_page_health/1" do
    test "takes bookings with a writable calendar and nothing refused" do
      user = insert(:user)
      insert(:calendar_integration, user: user, provider: "caldav")

      assert Calendar.booking_page_health(user.id) == :taking_bookings
    end

    test "has no calendar when only a read-only feed is connected" do
      user = insert(:user)
      ics(user)

      assert Calendar.booking_page_health(user.id) == :no_calendar
    end

    # A refused read-only feed blocks the page as surely as a refused writable
    # calendar: the availability read fails closed on either.
    test "names every active refused integration, read-only ones included" do
      user = insert(:user)
      insert(:calendar_integration, user: user, provider: "caldav", name: "Work")

      insert(:calendar_integration,
        user: user,
        provider: "apple",
        name: "iCloud",
        needs_reauth: true
      )

      ics(user, name: "Feed", needs_reauth: true)

      insert(:calendar_integration,
        user: user,
        provider: "caldav",
        name: "Old",
        needs_reauth: true,
        is_active: false
      )

      assert Calendar.booking_page_health(user.id) == {:credentials_refused, ["Feed", "iCloud"]}
    end

    # Polls still gate on a connected calendar, refused or not.
    test "leaves has_bookable_integration?/1 true for a refused writable calendar" do
      user = insert(:user)
      insert(:calendar_integration, user: user, provider: "apple", needs_reauth: true)

      assert Calendar.has_bookable_integration?(user.id)
      assert {:credentials_refused, [_name]} = Calendar.booking_page_health(user.id)
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
