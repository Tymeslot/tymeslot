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
  import Tymeslot.Test.GoogleMeetBooking

  alias Ecto.Changeset
  alias Tymeslot.Bookings.Cancel
  alias Tymeslot.Meetings.{CalendarEventSync, EmailVerification, MeetingSchema}
  alias Tymeslot.Repo
  alias Tymeslot.Test.ClockHelpers
  alias Tymeslot.Test.GoogleMeetFake
  alias Tymeslot.Workers.{CalendarEventWorker, VideoRoomWorker}

  setup :verify_on_exit!

  @meet_url GoogleMeetFake.meet_url()
  @space_url GoogleMeetFake.space_url()

  setup do
    %{user: user, meeting_type: meeting_type} = host = meet_host()
    Map.put(host, :meeting, book(user, meeting_type))
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
    # Past the wait, counted from the booking and from the Meet's request.
    ClockHelpers.freeze_clock(DateTime.add(DateTime.utc_now(), 3, :minute))
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

  # A 400 for another reason than the Meet would be refused again without
  # it, so the event is not written a second time.
  test "a calendar refusing the event itself does not have it written again without the Meet",
       %{meeting: meeting} do
    use_runtime_calendar()
    GoogleMeetFake.start(refuse_events: true)

    assert %{discard: 1} = Oban.drain_queue(queue: :calendar_events)

    assert [{:post, _refused, %{"conferenceData" => _asked}}] =
             for(
               {method, _uri, _body} = req <- GoogleMeetFake.requests(),
               method != :get,
               do: req
             )

    assert Repo.get!(MeetingSchema, meeting.id).provider_event_id == nil
  end

  # An update that runs before the booking's create finds no event, and
  # creates it as the first create would, Meet included.
  test "an update that finds no event creates it, without the Meet a calendar refuses", %{
    meeting: meeting
  } do
    use_runtime_calendar()
    GoogleMeetFake.start(refuse_conference: true)

    assert :ok = CalendarEventSync.update(meeting.id, 1)

    assert [
             {:put, _missing, _update},
             {:post, _refused, %{"conferenceData" => _asked}},
             {:post, _created, created}
           ] =
             for(
               {method, _uri, _body} = req <- GoogleMeetFake.requests(),
               method != :get,
               do: req
             )

    refute Map.has_key?(created, "conferenceData")
    assert Repo.get!(MeetingSchema, meeting.id).provider_event_id == created["id"]
  end
end
