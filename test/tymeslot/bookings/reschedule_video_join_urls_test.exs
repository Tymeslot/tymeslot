defmodule Tymeslot.Bookings.RescheduleVideoJoinUrlsTest do
  @moduledoc """
  Join links whose validity depends on the meeting time must follow the meeting
  when it is rescheduled.

  A Jitsi server with token authentication admits a participant only until
  four hours after the start time the token was minted for. The links are
  minted once, when the room is attached, and then stored and reused by the
  reschedule email, the agenda and webhook payloads, so a meeting moved a week
  later would otherwise hand both participants links that have already
  expired by the time the meeting starts.

  Every reschedule here goes through `Reschedule.execute/4` against the real
  email service, so the link the attendee is sent is the one asserted on.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :bookings
  @moduletag :integrations
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.Factory

  alias Ecto.UUID
  alias Joken.Signer
  alias Tymeslot.Bookings.Reschedule
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.VideoRooms
  alias Tymeslot.Test.LogCapture
  alias Tymeslot.TestMocks

  @app_id "tymeslot"
  @secret "jitsi-shared-secret-of-at-least-32-bytes"
  @grace_seconds 4 * 60 * 60
  @jitsi_server "https://meet.example.com"

  # Links a refresh would never produce, so a test can tell "left alone" apart
  # from "rebuilt into something identical".
  @stored_organizer_url "https://stored.example.com/organiser-link"
  @stored_attendee_url "https://stored.example.com/attendee-link"

  setup :verify_on_exit!

  setup do
    TestMocks.setup_email_mocks()

    original_service = Application.get_env(:tymeslot, :email_service_module)
    Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)

    # Delivery runs inside the circuit-breaker process, so the Swoosh test
    # adapter is pointed back at this test to collect what was sent. Safe
    # because the module is `async: false`.
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:tymeslot, :email_service_module, original_service)
      Application.delete_env(:swoosh, :shared_test_process)
    end)

    %{user: user} = create_always_bookable_profile()

    %{user: user}
  end

  describe "a Jitsi booking with token credentials" do
    setup %{user: user} do
      integration = create_jitsi(user, client_id: @app_id, client_secret: @secret)
      meeting = insert_meeting(user, %{video_integration_id: integration.id})

      assert {:ok, attached} = VideoRooms.add_video_room_to_meeting(meeting.id)

      # Anchors the test: the links really are time-bound before the move.
      assert verified_claims(attached.attendee_video_url)["exp"] ==
               DateTime.to_unix(attached.start_time) + @grace_seconds

      %{meeting: attached}
    end

    test "mints both join links again for the new start time, in the same room", %{
      user: user,
      meeting: meeting
    } do
      new_start = DateTime.add(meeting.start_time, 7, :day)

      assert {:ok, updated} =
               Reschedule.execute(meeting.uid, reschedule_params_for(new_start), %{}, user.id)

      assert DateTime.compare(updated.start_time, new_start) == :eq

      {:ok, stored} = MeetingQueries.get_meeting(meeting.id)

      assert stored.meeting_url == meeting.meeting_url
      assert stored.video_room_id == meeting.video_room_id

      organiser = verified_claims(stored.organizer_video_url)
      attendee = verified_claims(stored.attendee_video_url)

      expected_exp = DateTime.to_unix(new_start) + @grace_seconds
      assert organiser["exp"] == expected_exp
      assert attendee["exp"] == expected_exp

      assert organiser["context"]["user"]["moderator"] == true
      assert attendee["context"]["user"]["moderator"] == false
      assert organiser["room"] == meeting.video_room_id
      assert attendee["room"] == meeting.video_room_id

      # The caller is handed the refreshed meeting, not the stale one.
      assert updated.organizer_video_url == stored.organizer_video_url
      assert updated.attendee_video_url == stored.attendee_video_url
    end

    test "sends the attendee the refreshed link in the reschedule email", %{
      user: user,
      meeting: meeting
    } do
      new_start = DateTime.add(meeting.start_time, 7, :day)

      assert {:ok, _updated} =
               Reschedule.execute(meeting.uid, reschedule_params_for(new_start), %{}, user.id)

      {:ok, stored} = MeetingQueries.get_meeting(meeting.id)
      refute stored.attendee_video_url == meeting.attendee_video_url

      attendee_email = delivered_emails()[meeting.attendee_email]

      assert attendee_email.html_body =~ stored.attendee_video_url
      refute attendee_email.html_body =~ meeting.attendee_video_url
    end
  end

  describe "bookings whose join links do not depend on the meeting time" do
    test "leaves a kMeet booking's stored links alone", %{user: user} do
      {:ok, integration} = Video.create_integration(user.id, :kmeet, %{name: "My kMeet"})

      meeting =
        insert_meeting(
          user,
          stored_room_attrs(integration, "kmeet", "https://kmeet.infomaniak.com/0123456789abcdef")
        )

      assert_links_untouched_by_reschedule(user, meeting)
    end

    test "leaves a Jitsi booking without credentials alone", %{user: user} do
      integration = create_jitsi(user, [])

      meeting =
        insert_meeting(
          user,
          stored_room_attrs(integration, "jitsi", @jitsi_server <> "/0123456789abcdef")
        )

      assert_links_untouched_by_reschedule(user, meeting)
    end
  end

  describe "a Jitsi booking whose integration can no longer be used" do
    test "quietly keeps the stored links when the integration is inactive", %{user: user} do
      LogCapture.attach()

      integration = create_jitsi(user, client_id: @app_id, client_secret: @secret)
      assert {:ok, %{is_active: false}} = Video.toggle_integration(user.id, integration.id)

      meeting =
        insert_meeting(
          user,
          stored_room_attrs(integration, "jitsi", @jitsi_server <> "/0123456789abcdef")
        )

      assert_links_untouched_by_reschedule(user, meeting)
      refute_refresh_failure_logged()
    end

    test "quietly keeps the stored links when the integration was deleted", %{user: user} do
      LogCapture.attach()

      integration = create_jitsi(user, client_id: @app_id, client_secret: @secret)

      meeting =
        insert_meeting(
          user,
          stored_room_attrs(integration, "jitsi", @jitsi_server <> "/0123456789abcdef")
        )

      assert {:ok, :deleted} = Video.delete_integration(user.id, integration.id)

      assert_links_untouched_by_reschedule(user, meeting)
      refute_refresh_failure_logged()
    end
  end

  describe "a refresh that fails" do
    test "still reschedules, keeps the stored links and logs neither the secret nor a token",
         %{user: user} do
      LogCapture.attach()

      integration = create_jitsi(user, client_id: @app_id, client_secret: @secret)

      # A room with no URL cannot carry a token, so building the link raises
      # inside the provider.
      meeting = insert_meeting(user, stored_room_attrs(integration, "jitsi", nil))

      assert_links_untouched_by_reschedule(user, meeting)

      dump = "Could not refresh join links" |> LogCapture.await_log() |> LogCapture.dump()
      assert dump =~ meeting.id
      refute dump =~ @secret
      refute dump =~ "eyJ"
    end
  end

  # ----- helpers -----

  # A booking with no usable integration is an ordinary state, not a fault.
  defp refute_refresh_failure_logged do
    refute Enum.any?(LogCapture.drain(), &(LogCapture.dump(&1) =~ "Could not refresh join links"))
  end

  defp assert_links_untouched_by_reschedule(user, meeting) do
    new_start = DateTime.add(meeting.start_time, 7, :day)

    assert {:ok, updated} =
             Reschedule.execute(meeting.uid, reschedule_params_for(new_start), %{}, user.id)

    {:ok, stored} = MeetingQueries.get_meeting(meeting.id)

    assert DateTime.compare(stored.start_time, new_start) == :eq
    assert stored.organizer_video_url == @stored_organizer_url
    assert stored.attendee_video_url == @stored_attendee_url
    assert stored.meeting_url == meeting.meeting_url
    assert stored.video_room_id == meeting.video_room_id
    assert updated.attendee_video_url == @stored_attendee_url
  end

  defp stored_room_attrs(integration, provider, meeting_url) do
    %{
      video_integration_id: integration.id,
      video_provider: provider,
      video_room_id: "0123456789abcdef",
      video_room_enabled: true,
      meeting_url: meeting_url,
      organizer_video_url: @stored_organizer_url,
      attendee_video_url: @stored_attendee_url
    }
  end

  defp create_jitsi(user, credentials) do
    attrs =
      Map.merge(%{name: "Our Jitsi", base_url: @jitsi_server}, Map.new(credentials))

    {:ok, integration} = Video.create_integration(user.id, :jitsi, attrs)
    integration
  end

  defp insert_meeting(user, attrs) do
    start_time = future_hour(3)

    insert(
      :meeting,
      Map.merge(
        %{
          uid: UUID.generate(),
          organizer_user_id: user.id,
          organizer_email: user.email,
          start_time: start_time,
          end_time: DateTime.add(start_time, 60, :minute),
          duration: 60,
          status: "confirmed"
        },
        attrs
      )
    )
  end

  # Whole hours, so the open schedule's slot grid always contains the time.
  defp future_hour(days) do
    %{
      DateTime.add(DateTime.utc_now(), days, :day)
      | minute: 0,
        second: 0,
        microsecond: {0, 0}
    }
  end

  defp reschedule_params_for(%DateTime{} = target_utc) do
    in_berlin = DateTime.shift_zone!(target_utc, "Europe/Berlin")

    %{
      date: Date.to_iso8601(DateTime.to_date(in_berlin)),
      time: Calendar.strftime(in_berlin, "%H:%M"),
      duration: "60min",
      user_timezone: "Europe/Berlin"
    }
  end

  defp delivered_emails do
    assert_received {:email, first}
    assert_received {:email, second}

    Map.new([first, second], fn email ->
      {email.to |> hd() |> elem(1), email}
    end)
  end

  # Verifying against the configured secret also proves the token is signed
  # with it.
  defp verified_claims(url) do
    %URI{query: query} = URI.parse(url)
    %{"jwt" => token} = URI.decode_query(query)

    assert {:ok, claims} = Joken.verify(token, Signer.create("HS256", @secret))
    claims
  end
end
