defmodule Tymeslot.Bookings.RescheduleLocationTest do
  @moduledoc """
  A reschedule that moves a meeting to a different location, through
  `Tymeslot.Bookings.Reschedule.execute/4`.

  The picker is the easy half. What these tests pin is the provider room in
  every direction: a video meeting moved somewhere else releases its room, a
  meeting moved onto video gets one, and a move that keeps the integration
  keeps the room.
  """

  # Not async: the Zoom release chain goes through the application-wide video
  # circuit breaker, which DataCase only resets between non-async modules.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.MeetingTestHelpers
  import Tymeslot.WorkerTestHelpers, only: [expect_mirotalk_success: 0]

  alias Tymeslot.Bookings.Reschedule
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.LocationOption
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.{VideoRoomWorker, VideoSyncWorker}
  alias Tymeslot.ZoomOAuthHelperMock

  setup :verify_on_exit!

  setup do
    TestMocks.setup_email_mocks()
    TestMocks.stub_no_calendar_events()

    %{user: user} = create_always_bookable_profile()
    zoom = insert_zoom_integration(user)
    mirotalk = insert(:video_integration, user: user, provider: "mirotalk", is_active: true)

    %{user: user, zoom: zoom, mirotalk: mirotalk}
  end

  defp office do
    %LocationOption{
      id: "loc-office",
      kind: "in_person",
      label: "Our office",
      details: "12 High Street",
      position: 0
    }
  end

  defp call_me(position) do
    %LocationOption{
      id: "loc-call",
      kind: "phone",
      label: "Phone call",
      collect_from_guest: true,
      position: position
    }
  end

  defp video(id, integration, position) do
    %LocationOption{
      id: id,
      kind: "video",
      label: "Video #{id}",
      video_integration_ids: [integration.id],
      position: position
    }
  end

  defp meeting_on(user, locations, meeting_attrs, type_attrs \\ []) do
    meeting_type =
      insert(
        :meeting_type,
        Keyword.merge(
          [user: user, user_id: user.id, duration_minutes: 60, locations: locations],
          type_attrs
        )
      )

    insert_meeting_for_user(
      user,
      Map.merge(%{meeting_type_id: meeting_type.id, status: "confirmed"}, meeting_attrs)
    )
  end

  defp zoom_meeting_attrs(zoom, option_id) do
    %{
      location: "https://zoom.us/j/123456789",
      location_kind: "video",
      location_option_id: option_id,
      video_integration_id: zoom.id,
      video_provider: "zoom",
      video_room_id: "123456789",
      meeting_url: "https://zoom.us/j/123456789",
      attendee_video_url: "https://zoom.us/j/123456789?role=participant",
      organizer_video_url: "https://zoom.us/s/123456789",
      video_room_enabled: true
    }
  end

  defp office_meeting_attrs do
    %{
      location: "Our office (12 High Street)",
      location_kind: "in_person",
      location_option_id: "loc-office"
    }
  end

  defp reschedule(meeting, choice) do
    params =
      Map.merge(
        %{
          date: Date.to_string(Date.add(Date.utc_today(), 2)),
          time: "2:00 PM",
          duration: "60min",
          user_timezone: "America/New_York"
        },
        choice
      )

    assert {:ok, _updated} =
             Reschedule.execute(meeting.uid, params, %{}, meeting.organizer_user_id)

    # Read back, so every assertion is about what was persisted.
    Repo.get!(MeetingSchema, meeting.id)
  end

  describe "a reschedule that keeps the location" do
    test "leaves a video meeting's join link and room alone", %{user: user, zoom: zoom} do
      meeting =
        meeting_on(
          user,
          [office(), video("loc-zoom", zoom, 1)],
          zoom_meeting_attrs(zoom, "loc-zoom")
        )

      updated = reschedule(meeting, %{location_option_id: "loc-zoom"})

      # Re-resolving the option would have replaced the join URL with its label.
      assert updated.location == "https://zoom.us/j/123456789"
      assert updated.video_room_id == "123456789"
      assert updated.attendee_video_url == meeting.attendee_video_url

      assert_enqueued(
        worker: VideoSyncWorker,
        args: %{"meeting_id" => meeting.id, "action" => "update"}
      )

      refute_enqueued(worker: VideoSyncWorker, args: %{"action" => "release"})
      refute_enqueued(worker: VideoRoomWorker)
    end

    test "ignores an option the meeting type does not offer", %{user: user} do
      # Booked on the second option, so falling back to the first, as a new
      # booking does with an unknown id, would be visible as a move.
      meeting =
        meeting_on(user, [office(), call_me(1)], %{
          location: "Phone call (+1 555 0100)",
          location_kind: "phone",
          location_option_id: "loc-call",
          attendee_phone: "+1 555 0100"
        })

      updated = reschedule(meeting, %{location_option_id: "loc-forged"})

      assert updated.location_option_id == "loc-call"
      assert updated.location == "Phone call (+1 555 0100)"
    end

    test "never moves an ad-hoc meeting, which has no locations of its own", %{user: user} do
      # A type the ad-hoc booking's duration would match, offering a phone call.
      insert(:meeting_type,
        user: user,
        user_id: user.id,
        name: "60 Minutes",
        duration_minutes: 60,
        locations: [office(), call_me(1)]
      )

      meeting = insert_meeting_for_user(user, %{meeting_type_id: nil, location: "Café"})

      updated = reschedule(meeting, %{location_option_id: "loc-call", location_phone: "+1 555"})

      assert updated.location == "Café"
      assert updated.location_option_id == nil
      assert updated.attendee_phone == nil
    end
  end

  describe "moving between locations without video" do
    test "records the new location and the booker's number", %{user: user} do
      meeting = meeting_on(user, [office(), call_me(1)], office_meeting_attrs())

      updated =
        reschedule(meeting, %{location_option_id: "loc-call", location_phone: " +1 555 0100 "})

      assert updated.location == "Phone call (+1 555 0100)"
      assert updated.location_kind == "phone"
      assert updated.location_option_id == "loc-call"
      assert updated.attendee_phone == "+1 555 0100"

      refute_enqueued(worker: VideoSyncWorker)
      refute_enqueued(worker: VideoRoomWorker)
    end

    test "a new number on the same phone option is a change", %{user: user} do
      meeting =
        meeting_on(user, [office(), call_me(1)], %{
          location: "Phone call (+1 555 0100)",
          location_kind: "phone",
          location_option_id: "loc-call",
          attendee_phone: "+1 555 0100"
        })

      updated =
        reschedule(meeting, %{location_option_id: "loc-call", location_phone: "+44 20 7946 0000"})

      assert updated.attendee_phone == "+44 20 7946 0000"
      assert updated.location == "Phone call (+44 20 7946 0000)"
    end
  end

  describe "moving a video meeting somewhere else" do
    test "detaches the room at once and deletes it on the provider", %{user: user, zoom: zoom} do
      meeting =
        meeting_on(
          user,
          [office(), video("loc-zoom", zoom, 1)],
          zoom_meeting_attrs(zoom, "loc-zoom")
        )

      updated = reschedule(meeting, %{location_option_id: "loc-office"})

      assert updated.location == "Our office (12 High Street)"
      assert updated.location_kind == "in_person"
      assert updated.video_integration_id == nil

      # No join link survives for a meeting that is no longer online, not even
      # for the moment before the provider call runs.
      assert %{
               video_room_id: nil,
               video_provider: nil,
               meeting_url: nil,
               attendee_video_url: nil,
               organizer_video_url: nil,
               video_room_enabled: false
             } = updated

      refute_enqueued(worker: VideoSyncWorker, args: %{"action" => "update"})
      refute_enqueued(worker: VideoRoomWorker)

      release_args = %{
        "action" => "release",
        "meeting_id" => meeting.id,
        "room_id" => "123456789",
        "video_provider" => "zoom",
        "video_integration_id" => zoom.id,
        "organizer_user_id" => user.id
      }

      assert_enqueued(worker: VideoSyncWorker, args: release_args)

      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :delete, url, _body, _headers, _opts ->
        assert url == "https://api.zoom.us/v2/meetings/123456789"
        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      assert :ok = perform_job(VideoSyncWorker, release_args)
    end

    test "moving it to another video integration releases the old room and creates a new one",
         %{user: user, zoom: zoom, mirotalk: mirotalk} do
      meeting =
        meeting_on(
          user,
          [video("loc-zoom", zoom, 0), video("loc-miro", mirotalk, 1)],
          zoom_meeting_attrs(zoom, "loc-zoom")
        )

      updated = reschedule(meeting, %{location_option_id: "loc-miro"})

      assert updated.video_integration_id == mirotalk.id
      assert updated.video_room_id == nil
      assert updated.location == "Video loc-miro"

      assert_enqueued(
        worker: VideoSyncWorker,
        args: %{
          "action" => "release",
          "room_id" => "123456789",
          "video_integration_id" => zoom.id
        }
      )

      assert_enqueued(
        worker: VideoRoomWorker,
        args: %{"meeting_id" => meeting.id, "announce" => "rescheduled"}
      )
    end

    test "picking another provider within the same option moves the room there",
         %{user: user, zoom: zoom, mirotalk: mirotalk} do
      both = %{video("loc-video", zoom, 0) | video_integration_ids: [zoom.id, mirotalk.id]}
      meeting = meeting_on(user, [office(), both], zoom_meeting_attrs(zoom, "loc-video"))

      updated =
        reschedule(meeting, %{
          location_option_id: "loc-video",
          location_video_integration_id: to_string(mirotalk.id)
        })

      assert updated.location_option_id == "loc-video"
      assert updated.video_integration_id == mirotalk.id
      assert updated.video_room_id == nil

      assert_enqueued(
        worker: VideoSyncWorker,
        args: %{
          "action" => "release",
          "room_id" => "123456789",
          "video_integration_id" => zoom.id
        }
      )

      assert_enqueued(
        worker: VideoRoomWorker,
        args: %{"meeting_id" => meeting.id, "announce" => "rescheduled"}
      )
    end

    test "keeping the option and its provider leaves the room alone",
         %{user: user, zoom: zoom, mirotalk: mirotalk} do
      # The meeting is on the option's second provider, so a reschedule that
      # re-derived the first would move it.
      both = %{video("loc-video", zoom, 0) | video_integration_ids: [mirotalk.id, zoom.id]}
      meeting = meeting_on(user, [office(), both], zoom_meeting_attrs(zoom, "loc-video"))

      updated =
        reschedule(meeting, %{
          location_option_id: "loc-video",
          location_video_integration_id: to_string(zoom.id)
        })

      assert updated.video_integration_id == zoom.id
      assert updated.video_room_id == "123456789"
      refute_enqueued(worker: VideoSyncWorker, args: %{"action" => "release"})
      refute_enqueued(worker: VideoRoomWorker)
    end

    test "moving between two options on the same integration keeps the room",
         %{user: user, zoom: zoom} do
      meeting =
        meeting_on(
          user,
          [video("loc-zoom", zoom, 0), video("loc-zoom-long", zoom, 1)],
          zoom_meeting_attrs(zoom, "loc-zoom")
        )

      updated = reschedule(meeting, %{location_option_id: "loc-zoom-long"})

      assert updated.location_option_id == "loc-zoom-long"
      assert updated.video_room_id == "123456789"
      assert updated.location == "https://zoom.us/j/123456789"

      assert_enqueued(
        worker: VideoSyncWorker,
        args: %{"meeting_id" => meeting.id, "action" => "update"}
      )

      refute_enqueued(worker: VideoSyncWorker, args: %{"action" => "release"})
      refute_enqueued(worker: VideoRoomWorker)
    end
  end

  describe "moving a meeting onto video" do
    test "creates a room on the chosen integration", %{user: user, zoom: zoom} do
      meeting = meeting_on(user, [office(), video("loc-zoom", zoom, 1)], office_meeting_attrs())

      updated = reschedule(meeting, %{location_option_id: "loc-zoom"})

      assert updated.video_integration_id == zoom.id
      assert updated.location_kind == "video"

      assert_enqueued(
        worker: VideoRoomWorker,
        args: %{"meeting_id" => meeting.id, "announce" => "rescheduled"}
      )

      refute_enqueued(worker: VideoSyncWorker)
    end

    test "tells the attendee about the move once the join link exists, not before",
         %{user: user, mirotalk: mirotalk} do
      test_pid = self()

      stub(EmailServiceMock, :send_reschedule_emails, fn details ->
        send(test_pid, {:reschedule_emails, details})
        {{:ok, :sent}, {:ok, :sent}}
      end)

      meeting =
        meeting_on(user, [office(), video("loc-miro", mirotalk, 1)], office_meeting_attrs())

      updated = reschedule(meeting, %{location_option_id: "loc-miro"})

      # Sent now, the email would have no room to link to.
      refute_received {:reschedule_emails, _details}

      [job] = all_enqueued(worker: VideoRoomWorker)
      expect_mirotalk_success()

      assert :ok = perform_job(VideoRoomWorker, job.args)

      assert_received {:reschedule_emails, details}
      assert details.attendee_video_url =~ "https://test.mirotalk.com/join/test-room-123"
      assert details.original_start_time == meeting.start_time
      assert details.start_time == updated.start_time
      refute_received {:reschedule_emails, _details}
    end

    test "tells the attendee straight away when no room is on its way",
         %{user: user, zoom: zoom} do
      test_pid = self()

      stub(EmailServiceMock, :send_reschedule_emails, fn details ->
        send(test_pid, {:reschedule_emails, details})
        {{:ok, :sent}, {:ok, :sent}}
      end)

      meeting =
        meeting_on(
          user,
          [video("loc-zoom", zoom, 0), video("loc-zoom-long", zoom, 1)],
          zoom_meeting_attrs(zoom, "loc-zoom")
        )

      reschedule(meeting, %{location_option_id: "loc-zoom-long"})

      assert_received {:reschedule_emails, %{attendee_video_url: url}}
      assert url =~ "https://zoom.us/j/123456789"
    end

    test "leaves room creation to the approval when the move re-enters the gate",
         %{user: user, zoom: zoom} do
      meeting =
        meeting_on(
          user,
          [office(), video("loc-zoom", zoom, 1)],
          office_meeting_attrs(),
          requires_approval: true,
          approval_window_hours: 12
        )

      updated = reschedule(meeting, %{location_option_id: "loc-zoom"})

      assert updated.status == "awaiting_approval"
      assert updated.video_integration_id == zoom.id
      refute_enqueued(worker: VideoRoomWorker)
    end

    test "leaves room creation to the payment when the booking is not yet paid for",
         %{user: user, zoom: zoom} do
      meeting =
        meeting_on(
          user,
          [office(), video("loc-zoom", zoom, 1)],
          Map.put(office_meeting_attrs(), :status, "awaiting_payment")
        )

      updated = reschedule(meeting, %{location_option_id: "loc-zoom"})

      assert updated.status == "awaiting_payment"
      assert updated.video_integration_id == zoom.id
      refute_enqueued(worker: VideoRoomWorker)
    end

    test "still releases the old room when the move re-enters the gate",
         %{user: user, zoom: zoom} do
      meeting =
        meeting_on(
          user,
          [office(), video("loc-zoom", zoom, 1)],
          zoom_meeting_attrs(zoom, "loc-zoom"),
          requires_approval: true,
          approval_window_hours: 12
        )

      updated = reschedule(meeting, %{location_option_id: "loc-office"})

      assert updated.status == "awaiting_approval"
      assert updated.video_room_id == nil

      assert_enqueued(
        worker: VideoSyncWorker,
        args: %{"action" => "release", "room_id" => "123456789"}
      )
    end
  end

  defp insert_zoom_integration(user) do
    insert(:video_integration,
      user: user,
      name: "Zoom",
      provider: "zoom",
      base_url: nil,
      api_key_encrypted: nil,
      tenant_id_encrypted: nil,
      client_id_encrypted: nil,
      client_secret_encrypted: nil,
      teams_user_id_encrypted: nil,
      access_token_encrypted: Encryption.encrypt("access-token"),
      refresh_token_encrypted: Encryption.encrypt("refresh-token"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      oauth_scope: "meeting:write:meeting meeting:update:meeting meeting:delete:meeting",
      provider_account_id: nil
    )
  end
end
