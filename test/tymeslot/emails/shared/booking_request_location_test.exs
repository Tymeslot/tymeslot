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

  describe "type/1" do
    test "a meeting with a video url is video" do
      meeting = build(:meeting, meeting_url: "https://meet.example/abc", location: nil)

      assert BookingRequestLocation.type(meeting) == :video
    end

    test "a held request with only a video integration reads as video too" do
      meeting = build(:meeting, meeting_url: nil, video_integration_id: 1, location: nil)

      assert BookingRequestLocation.type(meeting) == :video
    end

    test "phone and in-person are read straight off the location field" do
      assert BookingRequestLocation.type(
               build(:meeting, meeting_url: nil, location: "Phone Call")
             ) ==
               :phone

      assert BookingRequestLocation.type(build(:meeting, meeting_url: nil, location: "In Person")) ==
               :in_person
    end

    test "anything else, including no location at all, is custom" do
      meeting = build(:meeting, meeting_url: nil, video_integration_id: nil, location: nil)

      assert BookingRequestLocation.type(meeting) == :custom
    end
  end

  describe "the pre-existing twins delegate rather than keep their own copy" do
    test "AppointmentBuilder classifies a video meeting the same way" do
      meeting = build(:meeting, meeting_url: "https://meet.example/abc", location: nil)

      details = AppointmentBuilder.from_meeting(meeting)

      assert details.location_type == BookingRequestLocation.type(meeting)
    end

    test "RescheduleRequest classifies a phone meeting the same way" do
      meeting =
        build(:meeting, meeting_url: nil, location: "Phone Call", reschedule_url: "https://x")

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
