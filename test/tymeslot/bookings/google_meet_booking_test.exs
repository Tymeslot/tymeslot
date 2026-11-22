defmodule Tymeslot.Bookings.GoogleMeetBookingTest do
  @moduledoc """
  A booking whose Google Calendar and Google Meet integration are the same
  Google account, from the public booking through both jobs it sets off: the
  calendar job that writes the booking's Google event, and the video job that
  gives the booking its Meet link.

  Google Calendar replaces a Meet code made outside Calendar with one made for
  the event, so a standalone Meet space written into the event leaves the
  guest's link and the event's own Meet link pointing at different rooms. The
  booking's event is therefore created asking Google for a Meet, and the
  booking takes that Meet's link. The two jobs run on separate queues and
  either can go first, so both orders are walked here, through the real Google
  Calendar client with only HTTP mocked.
  """

  # Not async: the calendar module and the Google Calendar API module are
  # swapped application-wide for the real ones.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :calendar
  @moduletag :video
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.Bookings.{Cancel, Orchestrator, Reschedule, RescheduleLocation}
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI
  alias Tymeslot.Integrations.Calendar.Runtime.Operations
  alias Tymeslot.Meetings.{EmailVerification, MeetingSchema}
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Test.GoogleMeetFake
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.{CalendarEventWorker, VideoRoomWorker}

  setup :verify_on_exit!

  @account_id "google-sub-organiser"
  @calendar_id GoogleMeetFake.calendar_id()
  @meet_url GoogleMeetFake.meet_url()
  @space_url GoogleMeetFake.space_url()

  setup do
    TestMocks.setup_calendar_mocks()
    TestMocks.setup_email_mocks()
    # The booking records the calendar its host's integrations really choose.
    TestMocks.resolve_booking_calendars()

    %{user: user} = create_always_bookable_profile()

    insert(:calendar_integration,
      user: user,
      provider: "google",
      provider_account_id: @account_id,
      oauth_scope: "https://www.googleapis.com/auth/calendar",
      access_token_encrypted: Encryption.encrypt("google-access-token"),
      refresh_token_encrypted: Encryption.encrypt("google-refresh-token"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      default_booking_calendar_id: @calendar_id
    )

    meet =
      insert(:video_integration,
        user: user,
        name: "Google Meet",
        provider: "google_meet",
        base_url: nil,
        api_key_encrypted: nil,
        access_token_encrypted: Encryption.encrypt("google-access-token"),
        refresh_token_encrypted: Encryption.encrypt("google-refresh-token"),
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        oauth_scope:
          "https://www.googleapis.com/auth/calendar https://www.googleapis.com/auth/meetings.space.created",
        provider_account_id: @account_id
      )

    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "Meet Consultation",
        duration_minutes: 30,
        is_active: true,
        allow_video: true,
        video_integration_id: meet.id
      )

    %{user: user, meeting_type: meeting_type, meeting: book(user, meeting_type)}
  end

  test "calendar job first: the booking takes the Meet Google made on its event", %{
    meeting: meeting
  } do
    use_runtime_calendar()
    GoogleMeetFake.start()

    run_calendar_jobs()
    assert :ok = run_video_job(meeting)
    run_calendar_jobs()

    assert_one_event_carrying_the_meet(meeting)
  end

  test "video job first: it waits for the booking's event rather than making a Meet of its own",
       %{meeting: meeting} do
    use_runtime_calendar()
    GoogleMeetFake.start()

    # The booking's own video job runs before the calendar's, and hands over to
    # a fresh job a few seconds out, still owing the booking its announcement.
    assert %{success: 1, failure: 0, discard: 0} = Oban.drain_queue(queue: :video_rooms)
    assert GoogleMeetFake.requests() == []

    assert_enqueued(
      worker: VideoRoomWorker,
      args: %{"meeting_id" => meeting.id, "announce" => true}
    )

    run_calendar_jobs()

    assert %{success: 1, failure: 0, discard: 0} =
             Oban.drain_queue(queue: :video_rooms, with_scheduled: true)

    run_calendar_jobs()

    assert_one_event_carrying_the_meet(meeting)
  end

  test "moving the booking off Meet takes the Meet off its event, rather than replacing the event",
       %{meeting: meeting} do
    use_runtime_calendar()
    GoogleMeetFake.start()

    run_calendar_jobs()
    assert :ok = run_video_job(meeting)
    run_calendar_jobs()
    assert_one_event_carrying_the_meet(meeting)

    original = Repo.get!(MeetingSchema, meeting.id)

    moved =
      original
      |> Changeset.change(
        video_room_id: nil,
        meeting_url: nil,
        video_integration_id: nil,
        location: "Somewhere in person"
      )
      |> Repo.update!()

    assert :ok = RescheduleLocation.release_abandoned_room(moved, original)
    run_calendar_jobs()

    # Written in place, with the conference left out at
    # `conferenceDataVersion=1`: a new event at the booking's id would be
    # refused by Google as a duplicate of the old one.
    assert [{:put, put_uri, put_body}] =
             for(
               {method, _uri, _body} = req <- GoogleMeetFake.requests(),
               method != :get,
               do: req
             )

    assert put_uri.path =~ "/events/#{original.provider_event_id}"
    assert URI.decode_query(put_uri.query)["conferenceDataVersion"] == "1"
    refute Map.has_key?(put_body, "conferenceData")
  end

  # A booking held for its attendee's email sets off both jobs only once the
  # address is verified, which can be long after it was made; the wait for
  # its event runs from then, so the event is still created with the Meet.
  test "a booking verified long after it was made still gets the Meet on its event", %{
    user: user,
    meeting_type: meeting_type
  } do
    Repo.delete_all(Oban.Job)

    verified_type =
      meeting_type |> Changeset.change(requires_email_verification: true) |> Repo.update!()

    assert {:ok, held} = submit(user, verified_type, "16:00")
    assert held.status == :awaiting_verification
    refute_enqueued(worker: CalendarEventWorker)

    use_runtime_calendar()
    GoogleMeetFake.start()

    held
    |> Changeset.change(inserted_at: DateTime.add(held.inserted_at, -3600, :second))
    |> Repo.update!()

    assert {:ok, :verified, verified} =
             EmailVerification.verify(Repo.get!(MeetingSchema, held.id))

    run_calendar_jobs()
    assert :ok = run_video_job(verified)
    run_calendar_jobs()

    assert_one_event_carrying_the_meet(held)
  end

  # The Meet is the booking's room again by the time the calendar job would
  # take it off, so it stays on the event and the video job takes it back.
  test "moving the booking off Meet and straight back keeps the Meet on its event",
       %{meeting: meeting} do
    use_runtime_calendar()
    GoogleMeetFake.start()

    run_calendar_jobs()
    assert :ok = run_video_job(meeting)
    run_calendar_jobs()
    assert_one_event_carrying_the_meet(meeting)

    original = Repo.get!(MeetingSchema, meeting.id)

    moved =
      original
      |> Changeset.change(video_room_id: nil, meeting_url: nil, video_integration_id: nil)
      |> Repo.update!()

    assert :ok = RescheduleLocation.release_abandoned_room(moved, original)

    moved
    |> Changeset.change(video_integration_id: original.video_integration_id)
    |> Repo.update!()

    run_calendar_jobs()
    assert :ok = run_video_job(meeting)

    requests = GoogleMeetFake.requests()
    assert for({method, _uri, _body} = req <- requests, method != :get, do: req) == []

    assert for({_method, %URI{host: "meet.googleapis.com"} = uri, _body} <- requests, do: uri) ==
             []

    back = Repo.get!(MeetingSchema, meeting.id)
    assert back.video_room_id == original.provider_event_id
    assert back.provider_event_id == original.provider_event_id
    assert back.meeting_url == @meet_url
  end

  test "the attendee's confirmation email carries the Meet on the booking's event", %{
    meeting: meeting
  } do
    use_runtime_calendar()
    use_real_emails()
    GoogleMeetFake.start()

    run_calendar_jobs()
    assert :ok = run_video_job(meeting)
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :emails)

    attendee_emails =
      for {:email, email} <- received_emails(), {_name, "ada@example.com"} <- email.to, do: email

    assert [confirmation] = attendee_emails
    assert confirmation.html_body =~ @meet_url
    assert confirmation.text_body =~ @meet_url
  end

  # Google never finishes the Meet it was asked for, so the wait ends and the
  # booking takes a Meet space of its own rather than none.
  test "an event whose Meet is still pending after the wait gets a Meet space of its own", %{
    meeting: meeting
  } do
    use_runtime_calendar()
    GoogleMeetFake.start(meet_pending: true)

    run_calendar_jobs()
    booked_minutes_ago(meeting, 3)
    assert :ok = run_video_job(meeting)
    run_calendar_jobs()

    requests = GoogleMeetFake.requests()

    assert [{:post, %URI{path: "/v2/spaces"}, _body}] =
             for({_method, %URI{host: "meet.googleapis.com"}, _body} = req <- requests, do: req)

    # The calendar update carries the space's link, and leaves the event's
    # conference alone: no second write at `conferenceDataVersion=1`.
    assert [{:post, _create_uri, created}, {:put, put_uri, put_body}] =
             for(
               {method, %URI{host: "www.googleapis.com"}, _body} = req <- requests,
               method != :get,
               do: req
             )

    assert put_uri.path =~ "/events/#{created["id"]}"
    refute URI.decode_query(put_uri.query || "")["conferenceDataVersion"] == "1"
    assert put_body["description"] =~ @space_url

    updated = Repo.get!(MeetingSchema, meeting.id)
    assert updated.provider_event_id == created["id"]
    assert updated.video_room_id == "space-1"
    assert updated.meeting_url == @space_url
  end

  # A booking given a standalone Meet space before its Meet was made with its
  # event: its event carries no conference, and its room is the space.
  test "a booking with a Meet space of its own is moved and cancelled through the Meet API",
       %{meeting: meeting, meeting_type: meeting_type} do
    use_runtime_calendar()
    GoogleMeetFake.start()

    meeting
    |> Changeset.change(
      video_room_id: "legacy-space",
      meeting_url: @space_url,
      video_provider: "google_meet",
      inserted_at: DateTime.add(meeting.inserted_at, -3600, :second)
    )
    |> Repo.update!()

    run_calendar_jobs()

    assert [{:post, _uri, created}] =
             for(
               {method, _uri, _body} = req <- GoogleMeetFake.requests(),
               method != :get,
               do: req
             )

    refute Map.has_key?(created, "conferenceData")

    original = Repo.get!(MeetingSchema, meeting.id)
    new_start = DateTime.add(original.start_time, 3600, :second)

    assert {:ok, moved} =
             Reschedule.apply_new_time(
               original,
               %{
                 start_time: new_start,
                 end_time: DateTime.add(new_start, 30, :minute),
                 duration_minutes: 30
               },
               meeting_type,
               %{},
               host_chosen: true
             )

    run_calendar_jobs()
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :video_rooms)

    assert [{:put, put_uri, put_body}] =
             for(
               {method, %URI{host: "www.googleapis.com"}, _body} = req <-
                 GoogleMeetFake.requests(),
               method != :get,
               do: req
             )

    assert put_uri.path =~ "/events/#{original.provider_event_id}"
    refute URI.decode_query(put_uri.query || "")["conferenceDataVersion"] == "1"
    refute Map.has_key?(put_body, "conferenceData")

    assert {:ok, _cancelled} = Cancel.execute(Repo.get!(MeetingSchema, moved.id))
    run_calendar_jobs()
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :video_rooms)

    requests = GoogleMeetFake.requests()

    assert [{:post, end_uri, _body}] =
             for({_method, %URI{host: "meet.googleapis.com"}, _body} = req <- requests, do: req)

    assert end_uri.path == "/v2/spaces/legacy-space:endActiveConference"

    assert [{:delete, delete_uri, _body}] =
             for({:delete, _uri, _body} = req <- requests, do: req)

    assert delete_uri.path =~ "/events/#{original.provider_event_id}"
  end

  # The Meet is the event's: deleting the event ends it, and the Meet API is
  # never asked about the event's id.
  test "cancelling a booking whose Meet is on its event deletes the event once", %{
    meeting: meeting
  } do
    use_runtime_calendar()
    GoogleMeetFake.start()

    run_calendar_jobs()
    assert :ok = run_video_job(meeting)
    run_calendar_jobs()
    assert_one_event_carrying_the_meet(meeting)

    booked = Repo.get!(MeetingSchema, meeting.id)
    assert {:ok, _cancelled} = Cancel.execute(booked)
    run_calendar_jobs()
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :video_rooms)

    requests = GoogleMeetFake.requests()

    assert for({_method, %URI{host: "meet.googleapis.com"} = uri, _body} <- requests, do: uri) ==
             []

    assert [{:delete, delete_uri, _body}] =
             for({method, _uri, _body} = req <- requests, method != :get, do: req)

    assert delete_uri.path =~ "/events/#{booked.provider_event_id}"
  end

  test "a calendar refusing the Meet still gets the booking's event, without it", %{
    meeting: meeting
  } do
    use_runtime_calendar()
    GoogleMeetFake.start(refuse_conference: true)

    run_calendar_jobs()

    assert [{:post, _refused, %{"conferenceData" => _asked}}, {:post, _created, created}] =
             for(
               {method, _uri, _body} = req <- GoogleMeetFake.requests(),
               method != :get,
               do: req
             )

    refute Map.has_key?(created, "conferenceData")
    assert Repo.get!(MeetingSchema, meeting.id).provider_event_id == created["id"]
  end

  defp assert_one_event_carrying_the_meet(meeting) do
    requests = GoogleMeetFake.requests()

    # A POST to the Meet API would be a standalone Meet space, the room that
    # Google Calendar later replaces with a second link.
    assert for({_method, %URI{host: "meet.googleapis.com"} = uri, _body} <- requests, do: uri) ==
             []

    # One write in all: the calendar job creating the booking's event, asking
    # Google for its Meet.
    assert [{:post, post_uri, created}] =
             for({method, _uri, _body} = req <- requests, method != :get, do: req)

    assert GoogleMeetFake.calendar_of(post_uri) == @calendar_id
    assert String.ends_with?(post_uri.path, "/events")
    assert URI.decode_query(post_uri.query)["conferenceDataVersion"] == "1"

    assert %{"createRequest" => %{"conferenceSolutionKey" => %{"type" => "hangoutsMeet"}}} =
             created["conferenceData"]

    assert ["ada@example.com"] = for(a <- created["attendees"], do: a["email"])

    updated = Repo.get!(MeetingSchema, meeting.id)
    assert updated.provider_event_id == created["id"]
    assert updated.video_room_id == created["id"]
    assert updated.meeting_url == @meet_url
    assert updated.uid == meeting.uid
  end

  defp book(user, meeting_type) do
    assert {:ok, booked} = submit(user, meeting_type)

    assert_enqueued(worker: VideoRoomWorker, args: %{"meeting_id" => booked.id})

    assert_enqueued(
      worker: CalendarEventWorker,
      args: %{"meeting_id" => booked.id, "action" => "create"}
    )

    booked
  end

  defp submit(user, meeting_type, time \\ "14:00") do
    params = %{
      form_data: %{"name" => "Ada Attendee", "email" => "ada@example.com", "message" => ""},
      meeting_params: %{
        date: Date.add(Date.utc_today(), 2),
        time: time,
        duration: "30min",
        user_timezone: "Europe/London",
        organizer_user_id: user.id,
        meeting_type_id: meeting_type.id,
        with_video_room: true
      }
    }

    Orchestrator.submit_booking(params, organizer_user_id: user.id)
  end

  # As if the booking had been made `minutes` ago, past the wait for its event.
  defp booked_minutes_ago(meeting, minutes) do
    meeting
    |> Changeset.change(inserted_at: DateTime.add(meeting.inserted_at, -60 * minutes, :second))
    |> Repo.update!()
  end

  defp use_real_emails do
    email_service = Application.get_env(:tymeslot, :email_service_module)
    Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:tymeslot, :email_service_module, email_service)
      Application.delete_env(:swoosh, :shared_test_process)
    end)
  end

  defp received_emails do
    receive do
      {:email, _email} = received -> [received | received_emails()]
    after
      0 -> []
    end
  end

  defp run_video_job(meeting),
    do: perform_job(VideoRoomWorker, %{"meeting_id" => meeting.id, "announce" => true})

  defp run_calendar_jobs do
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :calendar_events)
  end

  defp use_runtime_calendar do
    calendar_module = Application.get_env(:tymeslot, :calendar_module)
    google_api = Application.get_env(:tymeslot, :google_calendar_api_module)
    Application.put_env(:tymeslot, :calendar_module, Operations)
    Application.put_env(:tymeslot, :google_calendar_api_module, CalendarAPI)

    on_exit(fn ->
      Application.put_env(:tymeslot, :calendar_module, calendar_module)
      Application.put_env(:tymeslot, :google_calendar_api_module, google_api)
    end)
  end
end
