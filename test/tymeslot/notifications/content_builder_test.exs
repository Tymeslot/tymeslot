defmodule Tymeslot.Notifications.ContentBuilderTest do
  use Tymeslot.DataCase, async: true

  @moduletag :notifications

  import Tymeslot.Factory

  alias Tymeslot.Notifications.ContentBuilder

  describe "build_cancellation_details/1" do
    test "includes attendee_locale from the meeting" do
      meeting = build(:meeting, attendee_locale: "de")
      details = ContentBuilder.build_cancellation_details(meeting)
      assert details.attendee_locale == "de"
    end

    test "defaults attendee_locale to en when nil" do
      meeting = build(:meeting, attendee_locale: nil)
      details = ContentBuilder.build_cancellation_details(meeting)
      assert details.attendee_locale == "en"
    end
  end

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
end
