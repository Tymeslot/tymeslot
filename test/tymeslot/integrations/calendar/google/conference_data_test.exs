defmodule Tymeslot.Integrations.Calendar.Google.ConferenceDataTest do
  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :video

  alias Tymeslot.Integrations.Calendar.Google.ConferenceData

  @made_meet %{
    "entryPoints" => [%{"entryPointType" => "video", "uri" => "https://meet.google.com/abc"}],
    "createRequest" => %{"requestId" => "tymeslot-booking-1-AB"}
  }

  describe "put_on_event/2" do
    test "a booking's request leaves the cached event recognised as awaiting the booking's Meet" do
      cached =
        ConferenceData.put_on_event(%{"id" => "event-1"}, ConferenceData.booking_create_request())

      assert cached["id"] == "event-1"
      assert ConferenceData.booking_conference?(cached)
      assert ConferenceData.meet_status(cached) == :pending
    end

    test "a removal leaves the cached event without a conference" do
      cached =
        ConferenceData.put_on_event(
          %{"id" => "event-1", "conferenceData" => @made_meet},
          ConferenceData.remove()
        )

      assert cached == %{"id" => "event-1"}
      assert ConferenceData.meet_status(cached) == :none
    end
  end
end
