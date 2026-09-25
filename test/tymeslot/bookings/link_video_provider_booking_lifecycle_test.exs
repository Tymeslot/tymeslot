defmodule Tymeslot.Bookings.LinkVideoProviderBookingLifecycleTest do
  @moduledoc """
  Bookings on kMeet and Jitsi integrations from end to end.

  Neither provider has a room object to create: a room is a URL derived from
  the meeting, on kMeet's fixed host or on the organiser's own Jitsi server. So
  the journey is about the links. Each booking goes through the booking
  submission and the room job it queues, then a reschedule and a cancellation,
  draining the jobs they queue. No step may send an HTTP request.

  A Jitsi server with token authentication is the one case whose links depend
  on the meeting time: each participant's token expires four hours after the
  start it was minted for, so a reschedule mints both again.
  """

  # Not async: the room job calls the provider from a supervised task, which
  # needs the global Mox mode.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :video
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Joken.Signer
  alias Tymeslot.Bookings.Cancel
  alias Tymeslot.Bookings.Orchestrator
  alias Tymeslot.Bookings.Reschedule
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Video
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.VideoRoomWorker
  alias Tymeslot.Workers.VideoSyncWorker

  @timezone "Europe/Berlin"
  @app_id "tymeslot"
  @secret "jitsi-shared-secret-of-at-least-32-bytes"
  @token_grace_seconds 4 * 60 * 60

  setup :verify_on_exit!

  setup do
    TestMocks.setup_calendar_mocks()
    TestMocks.setup_email_mocks()

    test = self()

    stub(HTTPClientMock, :request, fn method, url, _body, _headers, _opts ->
      send(test, {:http_request, method, url})
      {:error, %Mint.TransportError{reason: :econnrefused}}
    end)

    stub(HTTPClientMock, :post, fn url, _body, _headers, _opts ->
      send(test, {:http_request, :post, url})
      {:error, %Mint.TransportError{reason: :econnrefused}}
    end)

    %{user: user} = create_always_bookable_profile()
    %{user: user}
  end

  describe "a booking on a kMeet integration" do
    setup %{user: user} do
      {:ok, integration} = Video.create_integration(user.id, :kmeet, %{name: "My kMeet"})
      %{meeting_type: insert_meeting_type(user, integration)}
    end

    test "gets a room on the kMeet host that stays through a reschedule and is let go on cancellation",
         %{user: user, meeting_type: meeting_type} do
      booked = book(user, meeting_type, booking_start(3, 13), "Ada Lovelace")

      room_url = "https://kmeet.infomaniak.com/" <> slug(booked)

      assert %{
               video_provider: "kmeet",
               video_room_enabled: true,
               meeting_url: ^room_url,
               organizer_video_url: ^room_url,
               attendee_video_url: ^room_url
             } = with_room = Repo.reload!(booked)

      assert with_room.video_room_id == slug(booked)

      new_start = DateTime.add(booked.start_time, 2, :day)

      assert {:ok, _rescheduled} =
               Reschedule.execute(booked.uid, reschedule_params(new_start), %{}, user.id)

      assert_enqueued(worker: VideoSyncWorker, args: sync_args(booked, "update"))
      assert %{success: 1, failure: 0} = drain_video_rooms()

      rescheduled = Repo.reload!(booked)
      assert DateTime.compare(rescheduled.start_time, new_start) == :eq

      assert %{meeting_url: ^room_url, attendee_video_url: ^room_url} = rescheduled
      assert rescheduled.video_room_id == with_room.video_room_id

      # There is nothing on kMeet to delete, so cancelling only forgets the room.
      assert {:ok, _cancelled} = Cancel.execute(booked.uid)
      assert_enqueued(worker: VideoSyncWorker, args: sync_args(booked, "delete"))
      assert %{success: 1, failure: 0} = drain_video_rooms()

      assert %{status: "cancelled", video_room_id: nil} = Repo.reload!(booked)
      refute_received {:http_request, _method, _url}
    end

    test "gives two bookings two different rooms", %{user: user, meeting_type: meeting_type} do
      first = book(user, meeting_type, booking_start(3, 9), "Ada Lovelace")
      second = book(user, meeting_type, booking_start(3, 15), "Grace Hopper")

      first_url = Repo.reload!(first).meeting_url
      second_url = Repo.reload!(second).meeting_url

      assert first_url == "https://kmeet.infomaniak.com/" <> slug(first)
      assert second_url == "https://kmeet.infomaniak.com/" <> slug(second)
      refute first_url == second_url
      refute_received {:http_request, _method, _url}
    end
  end

  describe "a booking on a Jitsi integration without token authentication" do
    test "gets a bare room on the organiser's server that a reschedule leaves alone",
         %{user: user} do
      server = "https://meet.example.com"
      {:ok, integration} = create_jitsi(user, server, [])
      meeting_type = insert_meeting_type(user, integration)

      booked = book(user, meeting_type, booking_start(3, 13), "Ada Lovelace")
      room_url = server <> "/" <> slug(booked)

      assert %{
               video_provider: "jitsi",
               meeting_url: ^room_url,
               organizer_video_url: ^room_url,
               attendee_video_url: ^room_url
             } = Repo.reload!(booked)

      new_start = DateTime.add(booked.start_time, 2, :day)

      assert {:ok, _rescheduled} =
               Reschedule.execute(booked.uid, reschedule_params(new_start), %{}, user.id)

      assert %{success: 1, failure: 0} = drain_video_rooms()

      assert %{organizer_video_url: ^room_url, attendee_video_url: ^room_url} =
               Repo.reload!(booked)

      refute_received {:http_request, _method, _url}
    end
  end

  describe "a booking on a Jitsi integration with token authentication" do
    setup %{user: user} do
      server = "https://secure.example.com"
      {:ok, integration} = create_jitsi(user, server, client_id: @app_id, client_secret: @secret)
      %{server: server, meeting_type: insert_meeting_type(user, integration)}
    end

    test "gives each participant a token for the room, mints both again on reschedule and forgets the room on cancellation",
         %{user: user, server: server, meeting_type: meeting_type} do
      start_time = booking_start(3, 13)
      booked = book(user, meeting_type, start_time, "Grace Hopper")
      room = slug(booked)
      room_url = server <> "/" <> room

      with_room = Repo.reload!(booked)
      assert %{video_provider: "jitsi", video_room_id: ^room, meeting_url: ^room_url} = with_room

      assert_tokens(with_room, room_url, start_time)
      assert claims(with_room.attendee_video_url)["context"]["user"]["name"] == "Grace Hopper"

      # The new tokens are written with the new time, before any job runs, so
      # the reschedule emails already carry them.
      new_start = DateTime.add(start_time, 7, :day)

      assert {:ok, rescheduled} =
               Reschedule.execute(booked.uid, reschedule_params(new_start), %{}, user.id)

      stored = Repo.reload!(booked)
      assert stored.attendee_video_url == rescheduled.attendee_video_url
      refute stored.attendee_video_url == with_room.attendee_video_url
      refute stored.organizer_video_url == with_room.organizer_video_url
      assert %{video_room_id: ^room, meeting_url: ^room_url} = stored
      assert_tokens(stored, room_url, new_start)

      assert %{success: 1, failure: 0} = drain_video_rooms()
      assert_tokens(Repo.reload!(booked), room_url, new_start)

      assert {:ok, _cancelled} = Cancel.execute(booked.uid)
      assert %{success: 1, failure: 0} = drain_video_rooms()

      assert %{status: "cancelled", video_room_id: nil} = Repo.reload!(booked)
      refute_received {:http_request, _method, _url}
    end
  end

  # ----- links -----

  # The room is the first 16 hex characters of the meeting id's SHA-256.
  defp slug(meeting) do
    :sha256 |> :crypto.hash(meeting.id) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  # Both links carry a token signed with the integration's secret, for this
  # room only, valid until four hours after `start_time`. Only the organiser's
  # makes them a moderator.
  defp assert_tokens(meeting, room_url, start_time) do
    organiser = claims(meeting.organizer_video_url, room_url)
    attendee = claims(meeting.attendee_video_url, room_url)
    expires_at = DateTime.to_unix(start_time) + @token_grace_seconds

    assert %{"room" => room, "aud" => @app_id, "exp" => ^expires_at} = organiser
    assert %{"room" => ^room, "aud" => @app_id, "exp" => ^expires_at} = attendee
    assert room_url == meeting.meeting_url
    assert String.ends_with?(room_url, "/" <> room)
    assert organiser["context"]["user"]["moderator"] == true
    assert attendee["context"]["user"]["moderator"] == false
  end

  defp claims(url, room_url \\ nil) do
    %URI{query: query} = uri = URI.parse(url)
    if room_url, do: assert(URI.to_string(%URI{uri | query: nil}) == room_url)

    %{"jwt" => token} = URI.decode_query(query)
    assert {:ok, claims} = Joken.verify(token, Signer.create("HS256", @secret))
    claims
  end

  # ----- bookings -----

  # Submits a booking as the public form does, then runs the room job it
  # queues, which announces the booking once the room exists.
  defp book(user, meeting_type, start_time, attendee_name) do
    params = %{
      form_data: %{
        "name" => attendee_name,
        "email" => "guest#{System.unique_integer([:positive])}@example.com",
        "message" => "Looking forward to it"
      },
      meeting_params:
        Map.merge(slot_params(start_time), %{
          organizer_user_id: user.id,
          meeting_type_id: meeting_type.id,
          with_video_room: true
        })
    }

    assert {:ok, meeting} = Orchestrator.submit_booking(params, organizer_user_id: user.id)
    assert DateTime.compare(meeting.start_time, start_time) == :eq
    assert_enqueued(worker: VideoRoomWorker, args: %{"meeting_id" => meeting.id})

    assert %{success: 1, failure: 0} = drain_video_rooms()

    assert_enqueued(
      worker: EmailWorker,
      args: %{"action" => "send_confirmation_emails", "meeting_id" => meeting.id}
    )

    meeting
  end

  defp drain_video_rooms, do: Oban.drain_queue(queue: :video_rooms)

  defp sync_args(meeting, action), do: %{"meeting_id" => meeting.id, "action" => action}

  defp reschedule_params(start_time), do: slot_params(start_time)

  defp slot_params(start_time) do
    local = DateTime.shift_zone!(start_time, @timezone)

    %{
      date: Date.to_iso8601(DateTime.to_date(local)),
      time: Calendar.strftime(local, "%H:%M"),
      duration: "30min",
      user_timezone: @timezone
    }
  end

  # A whole hour, `days` from now, so the open schedule always offers it.
  defp booking_start(days, hour) do
    %{
      DateTime.add(DateTime.utc_now(), days, :day)
      | hour: hour,
        minute: 0,
        second: 0,
        microsecond: {0, 0}
    }
  end

  defp insert_meeting_type(user, integration) do
    insert(:meeting_type,
      user: user,
      name: "Consultation",
      duration_minutes: 30,
      allow_video: true,
      video_integration_id: integration.id
    )
  end

  defp create_jitsi(user, server, credentials) do
    Video.create_integration(
      user.id,
      :jitsi,
      Map.merge(%{name: "Our Jitsi", base_url: server}, Map.new(credentials))
    )
  end
end
