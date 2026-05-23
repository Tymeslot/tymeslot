defmodule Tymeslot.Integrations.MeetingProvisioningTest do
  use Tymeslot.DataCase, async: false
  @moduletag :integrations

  import Tymeslot.Factory

  alias Tymeslot.Integrations.MeetingProvisioning

  describe "MeetingProvisioning.plan/3 — Google account overlap detection" do
    test "returns {:inline, vid_id} when both integrations are Google for the same account" do
      user = insert(:user)
      account_id = "11223344"

      cal =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          provider_account_id: account_id
        )

      vid =
        insert(:video_integration,
          user: user,
          provider: "google_meet",
          provider_account_id: account_id
        )

      assert MeetingProvisioning.plan(cal.id, vid.id, user.id) == {:inline, vid.id}
    end

    test "returns {:separate, vid_id} when the Google accounts differ" do
      user = insert(:user)

      cal =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          provider_account_id: "cal-account"
        )

      vid =
        insert(:video_integration,
          user: user,
          provider: "google_meet",
          provider_account_id: "different-account"
        )

      assert MeetingProvisioning.plan(cal.id, vid.id, user.id) == {:separate, vid.id}
    end

    test "returns {:separate, vid_id} when the calendar integration is non-Google" do
      user = insert(:user)
      account_id = "shared-account"

      cal =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          provider_account_id: account_id
        )

      vid =
        insert(:video_integration,
          user: user,
          provider: "google_meet",
          provider_account_id: account_id
        )

      assert MeetingProvisioning.plan(cal.id, vid.id, user.id) == {:separate, vid.id}
    end

    test "returns {:separate, vid_id} when the video integration is not Google Meet" do
      user = insert(:user)
      account_id = "shared-account"

      cal =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          provider_account_id: account_id
        )

      vid =
        insert(:video_integration,
          user: user,
          provider: "mirotalk",
          provider_account_id: account_id
        )

      assert MeetingProvisioning.plan(cal.id, vid.id, user.id) == {:separate, vid.id}
    end

    test "returns {:separate, vid_id} when provider_account_id is missing on either side" do
      user = insert(:user)

      cal =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          provider_account_id: nil
        )

      vid =
        insert(:video_integration,
          user: user,
          provider: "google_meet",
          provider_account_id: "some-account"
        )

      assert MeetingProvisioning.plan(cal.id, vid.id, user.id) == {:separate, vid.id}
    end

    test "returns :none when video_integration_id is nil" do
      user = insert(:user)
      assert MeetingProvisioning.plan(1, nil, user.id) == :none
    end
  end

  describe "MeetingProvisioning.attach_conference_data/2" do
    test "{:inline, _} plan attaches :conference_data key with a createRequest map" do
      event_data = %{summary: "Planning", description: "Q4 plan"}
      result = MeetingProvisioning.attach_conference_data(event_data, {:inline, 42})

      assert %{createRequest: %{requestId: request_id, conferenceSolutionKey: _solution_key}} =
               result[:conference_data]

      assert is_binary(request_id) and request_id != ""
    end

    test "{:separate, _} plan returns event_data unchanged" do
      event_data = %{summary: "Planning", description: "Q4 plan"}
      result = MeetingProvisioning.attach_conference_data(event_data, {:separate, 42})

      assert result == event_data
    end

    test ":none plan returns event_data unchanged" do
      event_data = %{summary: "Planning", description: "Q4 plan"}
      result = MeetingProvisioning.attach_conference_data(event_data, :none)

      assert result == event_data
    end
  end
end
