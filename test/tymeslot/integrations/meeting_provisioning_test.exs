defmodule Tymeslot.Integrations.MeetingProvisioningTest do
  use Tymeslot.DataCase, async: false
  @moduletag :integrations

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.MeetingProvisioning
  alias Tymeslot.Meetings.MeetingSchema

  setup :verify_on_exit!

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

  describe "MeetingProvisioning.teams_room_placement/1" do
    # The booking's calendar is the one the resolver names for this very
    # meeting; answering for any other meeting would hide a caller that asks
    # about the wrong one.
    defp stub_booking_calendar(%MeetingSchema{id: meeting_id}, calendar_id) do
      stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn
        %MeetingSchema{id: ^meeting_id} ->
          {:ok, %{integration_id: calendar_id, calendar_path: "primary"}}
      end)
    end

    defp teams_booking(opts) do
      user = insert(:user)
      account_id = Keyword.get(opts, :video_account, "entra-oid-1")

      calendar =
        insert(:calendar_integration,
          user: user,
          provider: Keyword.get(opts, :calendar_provider, "outlook"),
          provider_account_id: Keyword.get(opts, :calendar_account, "entra-oid-1")
        )

      video =
        insert(:video_integration,
          user: user,
          provider: Keyword.get(opts, :video_provider, "teams"),
          provider_account_id: account_id
        )

      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          video_integration_id: video.id,
          calendar_integration_id: Keyword.get(opts, :mapped_calendar, calendar.id),
          provider_event_id: Keyword.get(opts, :provider_event_id),
          inserted_at: Keyword.get(opts, :inserted_at, DateTime.utc_now(:second))
        )

      %{user: user, calendar: calendar, video: video, meeting: meeting}
    end

    test "attaches to the booking's event when it is already in the same account's Outlook calendar" do
      %{calendar: calendar, meeting: meeting} = teams_booking(provider_event_id: "AAMk-event-1")
      stub_booking_calendar(meeting, calendar.id)

      assert MeetingProvisioning.teams_room_placement(meeting) ==
               {:calendar_event, "AAMk-event-1"}
    end

    test "waits for the booking's event when the same account's calendar has not written it yet" do
      %{calendar: calendar, meeting: meeting} = teams_booking(provider_event_id: nil)
      stub_booking_calendar(meeting, calendar.id)

      assert MeetingProvisioning.teams_room_placement(meeting) == :awaiting_calendar_event
    end

    test "stops waiting and creates its own event once the booking's event is overdue" do
      booked_at = DateTime.add(DateTime.utc_now(:second), -121, :second)

      %{calendar: calendar, meeting: meeting} =
        teams_booking(provider_event_id: nil, inserted_at: booked_at)

      stub_booking_calendar(meeting, calendar.id)

      assert MeetingProvisioning.teams_room_placement(meeting) == :own_event
    end

    test "waits when the stored event belongs to a different calendar integration" do
      user_calendar = insert(:calendar_integration, provider: "outlook")

      %{calendar: calendar, meeting: meeting} =
        teams_booking(provider_event_id: "AAMk-stale", mapped_calendar: user_calendar.id)

      stub_booking_calendar(meeting, calendar.id)

      assert MeetingProvisioning.teams_room_placement(meeting) == :awaiting_calendar_event
    end

    test "creates its own event when the Outlook calendar is another Microsoft account" do
      %{calendar: calendar, meeting: meeting} =
        teams_booking(calendar_account: "entra-oid-other", provider_event_id: "AAMk-event-1")

      stub_booking_calendar(meeting, calendar.id)

      assert MeetingProvisioning.teams_room_placement(meeting) == :own_event
    end

    test "creates its own event when the booking calendar is not Outlook" do
      %{calendar: calendar, meeting: meeting} =
        teams_booking(calendar_provider: "google", provider_event_id: "google-event-1")

      stub_booking_calendar(meeting, calendar.id)

      assert MeetingProvisioning.teams_room_placement(meeting) == :own_event
    end

    test "creates its own event when the booking has no calendar" do
      %{meeting: meeting} = teams_booking(provider_event_id: nil)

      stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _meeting ->
        {:error, :no_integration}
      end)

      assert MeetingProvisioning.teams_room_placement(meeting) == :own_event
    end

    test "is not asked about any provider but Teams, and never consults the calendar" do
      %{meeting: meeting} =
        teams_booking(video_provider: "google_meet", provider_event_id: "AAMk-event-1")

      expect(Tymeslot.CalendarMock, :get_booking_integration_info, 0, fn _meeting ->
        flunk("the booking calendar is irrelevant to a non-Teams room")
      end)

      assert MeetingProvisioning.teams_room_placement(meeting) == :own_event
    end
  end
end
