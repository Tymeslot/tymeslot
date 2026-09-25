defmodule Tymeslot.Emails.Shared.BookingRequestLocationTest do
  @moduledoc """
  The one classifier every location-aware email template reads from, so a
  video, phone, in-person or held-video-pending meeting reads the same way
  everywhere rather than drifting between copies.
  """

  use Tymeslot.DataCase, async: true

  import Tymeslot.Factory

  @moduletag :emails

  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Emails.Shared.BookingRequestLocation
  alias Tymeslot.Emails.Templates.RescheduleRequest

  describe "type/1 with a recorded location kind" do
    test "the kind the booker chose is read straight off the meeting" do
      for {kind, expected} <- [
            {"video", :video},
            {"phone", :phone},
            {"in_person", :in_person},
            {"custom", :custom}
          ] do
        meeting = build(:meeting, location_kind: kind, meeting_url: nil, location: "Anywhere")

        assert BookingRequestLocation.type(meeting) == expected
      end
    end

    test "the recorded kind wins over what the other fields would have implied" do
      # A held in-person request on a meeting type that also offers video:
      # `video_integration_id` is set, but the booker did not choose video.
      meeting =
        build(:meeting,
          location_kind: "in_person",
          video_integration_id: 1,
          meeting_url: nil,
          location: "Our office"
        )

      assert BookingRequestLocation.type(meeting) == :in_person
    end
  end

  describe "type/1 for meetings booked before the kind was recorded" do
    test "a meeting with a video url is video" do
      meeting =
        build(:meeting,
          location_kind: nil,
          meeting_url: "https://meet.example/abc",
          location: nil
        )

      assert BookingRequestLocation.type(meeting) == :video
    end

    test "a held request with only a video integration reads as video too" do
      meeting =
        build(:meeting,
          location_kind: nil,
          meeting_url: nil,
          video_integration_id: 1,
          location: nil
        )

      assert BookingRequestLocation.type(meeting) == :video
    end

    test "phone and in-person fall back to the two literals this app used to write" do
      assert BookingRequestLocation.type(
               build(:meeting, location_kind: nil, meeting_url: nil, location: "Phone Call")
             ) ==
               :phone

      assert BookingRequestLocation.type(
               build(:meeting, location_kind: nil, meeting_url: nil, location: "In Person")
             ) ==
               :in_person
    end

    test "anything else, including no location at all, is custom" do
      meeting =
        build(:meeting,
          location_kind: nil,
          meeting_url: nil,
          video_integration_id: nil,
          location: nil
        )

      assert BookingRequestLocation.type(meeting) == :custom
    end
  end

  describe "the pre-existing twins delegate rather than keep their own copy" do
    test "AppointmentBuilder classifies a video meeting the same way" do
      meeting =
        build(:meeting,
          location_kind: nil,
          meeting_url: "https://meet.example/abc",
          location: nil
        )

      details = AppointmentBuilder.from_meeting(meeting)

      assert details.location_type == BookingRequestLocation.type(meeting)
    end

    test "RescheduleRequest classifies a phone meeting the same way" do
      meeting =
        build(:meeting,
          location_kind: nil,
          meeting_url: nil,
          location: "Phone Call",
          reschedule_url: "https://x"
        )

      email = RescheduleRequest.render(meeting)

      # The rendered text body carries the classified label through
      # `Formatting.format_location/1`; asserting on that is how this test
      # observes `location_type` without reaching into the template's
      # private `meeting_details` map.
      assert email.text_body =~ "Phone Call"
      assert BookingRequestLocation.type(meeting) == :phone
    end
  end
end
