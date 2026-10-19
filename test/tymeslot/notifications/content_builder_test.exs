defmodule Tymeslot.Notifications.ContentBuilderTest do
  use Tymeslot.DataCase, async: true

  @moduletag :notifications

  import Tymeslot.Factory

  alias Tymeslot.Notifications.ContentBuilder

  describe "build_appointment_details/1" do
    test "includes attendee_locale from the meeting" do
      meeting = build(:meeting, attendee_locale: "fr")
      details = ContentBuilder.build_appointment_details(meeting)
      assert details.attendee_locale == "fr"
    end

    test "defaults attendee_locale to en when nil" do
      meeting = build(:meeting, attendee_locale: nil)
      details = ContentBuilder.build_appointment_details(meeting)
      assert details.attendee_locale == "en"
    end
  end

  describe "build_appointment_details/1 organiser avatar" do
    test "is an absolute URL to the uploaded avatar" do
      user = insert(:user)
      profile = insert(:profile, user: user, avatar: "photo.png")

      details =
        ContentBuilder.build_appointment_details(build(:meeting, organizer_user_id: user.id))

      assert details.organizer_avatar_url ==
               "http://localhost:4002/uploads/avatars/#{profile.id}/photo.png"
    end

    test "is nil, not a generated data URI, when the organiser has no uploaded avatar" do
      user = insert(:user)
      insert(:profile, user: user, avatar: nil)

      details =
        ContentBuilder.build_appointment_details(build(:meeting, organizer_user_id: user.id))

      assert details.organizer_avatar_url == nil
    end
  end
end
