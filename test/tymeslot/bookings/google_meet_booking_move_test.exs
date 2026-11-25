defmodule Tymeslot.Bookings.GoogleMeetBookingMoveTest do
  @moduledoc """
  A booking whose Google Calendar and Google Meet integration are the same
  Google account, moved onto Meet or off it after its Google event exists.

  Google Calendar replaces a Meet code made outside Calendar with one made
  for the event, so the booking's Meet is always the event's own: a move off
  Meet takes it off the event in place, and a move onto Meet asks the event
  for one in place, never making a Meet space of its own. Walked through the
  real Google Calendar client with only HTTP mocked.
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
  alias Tymeslot.Bookings.{Cancel, Reschedule, RescheduleLocation}
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.{CalendarEventSync, MeetingSchema}
  alias Tymeslot.MeetingTypes.LocationOption
  alias Tymeslot.Repo
  alias Tymeslot.Test.GoogleMeetFake

  setup :verify_on_exit!

  @calendar_id GoogleMeetFake.calendar_id()
  @meet_url GoogleMeetFake.meet_url()
  @space_url GoogleMeetFake.space_url()

  setup do
    %{user: user, meeting_type: meeting_type} = host = meet_host()
    Map.put(host, :meeting, book(user, meeting_type))
  end

  test "moving the booking off Meet takes the Meet off its event, rather than replacing the event",
       %{meeting: meeting} do
    use_runtime_calendar()
    GoogleMeetFake.start()

    original = book_onto_meet_then_move_off(meeting)
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

  # The Meet is the booking's room again by the time the calendar job would
  # take it off, so it stays on the event and the video job takes it back.
  test "moving the booking off Meet and straight back keeps the Meet on its event",
       %{meeting: meeting} do
    use_runtime_calendar()
    GoogleMeetFake.start()

    original = book_onto_meet_then_move_off(meeting)

    MeetingSchema
    |> Repo.get!(meeting.id)
    |> Changeset.change(video_integration_id: original.video_integration_id, location: nil)
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

  # The decision to take the Meet off was made before the booking moved back,
  # so the write removes it; the video job reads the event as the write left
  # it and asks the event for a new Meet, never taking the one just removed,
  # and never making a Meet space Google would replace. The video job's wait
  # for an in-flight write is not exercised here: the sandbox runs the whole
  # test on one connection, where the lock is re-entrant.
  test "a booking moved back to Meet while the Meet is taken off asks its event for a new Meet",
       %{meeting: meeting} do
    use_runtime_calendar()

    move_back = fn ->
      MeetingSchema
      |> Repo.get!(meeting.id)
      |> Changeset.change(video_integration_id: meeting.video_integration_id, location: nil)
      |> Repo.update!()
    end

    GoogleMeetFake.start(on_conference_removal: move_back)
    original = book_onto_meet_then_move_off(meeting)

    assert :ok = CalendarEventSync.replace(meeting.id, original.provider_event_id, 1)
    run_video_jobs(meeting)

    assert [{:put, removal_uri, removal}, {:put, request_uri, request}] =
             for(
               {method, _uri, _body} = req <- GoogleMeetFake.requests(),
               method != :get,
               do: req
             )

    assert URI.decode_query(removal_uri.query)["conferenceDataVersion"] == "1"
    refute Map.has_key?(removal, "conferenceData")

    assert request_uri.path =~ "/events/#{original.provider_event_id}"
    assert_booking_meet_request(request_uri, request)

    back = Repo.get!(MeetingSchema, meeting.id)
    assert back.video_integration_id == meeting.video_integration_id
    assert back.video_room_id == original.provider_event_id
    assert back.meeting_url == @meet_url
  end

  # The booking's Google event exists, without a Meet, when the booking is
  # moved onto Meet. A Meet space of its own would be replaced by Google with
  # a conference of the event's, leaving host and guest in different rooms,
  # so the event is asked for its Meet in place and the booking takes it.
  test "a booking moved onto Meet after its event exists takes the Meet asked for on that event",
       %{user: user, meet: meet} do
    Repo.delete_all(Oban.Job)
    use_runtime_calendar()
    use_real_emails()
    GoogleMeetFake.start()

    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "Meet or office",
        duration_minutes: 30,
        is_active: true,
        locations: [
          %LocationOption{
            id: "loc-meet",
            kind: :video,
            label: "Google Meet",
            video_integration_ids: [meet.id],
            position: 0
          },
          %LocationOption{
            id: "loc-office",
            kind: :in_person,
            label: "Our office",
            details: "12 High Street",
            position: 1
          }
        ]
      )

    assert {:ok, in_person} =
             submit(user, meeting_type, "16:00", %{location_option_id: "loc-office"})

    run_calendar_jobs()
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :emails)
    _confirmation = received_emails()

    assert [{:post, _create_uri, created}] =
             for(
               {method, _uri, _body} = req <- GoogleMeetFake.requests(),
               method != :get,
               do: req
             )

    refute Map.has_key?(created, "conferenceData")
    event_id = Repo.get!(MeetingSchema, in_person.id).provider_event_id

    # Moved long after it was booked, past the wait timed from the booking.
    MeetingSchema
    |> Repo.get!(in_person.id)
    |> Changeset.change(inserted_at: DateTime.add(in_person.inserted_at, -3600, :second))
    |> Repo.update!()

    assert {:ok, _moved} =
             Reschedule.execute(
               in_person.uid,
               %{
                 date: Date.to_string(Date.add(Date.utc_today(), 2)),
                 time: "5:00 PM",
                 duration: "30min",
                 user_timezone: "Europe/London",
                 location_option_id: "loc-meet"
               },
               user.id
             )

    run_calendar_jobs()
    run_video_jobs(in_person)
    run_calendar_jobs()
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :emails)

    requests = GoogleMeetFake.requests()

    assert for({_method, %URI{host: "meet.googleapis.com"} = uri, _body} <- requests, do: uri) ==
             []

    # Every write is to the one event, and one of them asks it for its Meet.
    writes = for {method, _uri, _body} = req <- requests, method != :get, do: req
    assert writes != []

    assert Enum.reject(writes, fn {method, uri, _body} ->
             method == :put and uri.path =~ "/events/#{event_id}"
           end) == []

    assert [{request_uri, request}] =
             for(
               {:put, uri, body} <- writes,
               URI.decode_query(uri.query || "")["conferenceDataVersion"] == "1",
               do: {uri, body}
             )

    assert_booking_meet_request(request_uri, request)

    moved = Repo.get!(MeetingSchema, in_person.id)
    assert moved.provider_event_id == event_id
    assert moved.video_room_id == event_id
    assert moved.meeting_url == @meet_url

    assert [rescheduled] =
             for(
               {:email, email} <- received_emails(),
               {_name, "ada@example.com"} <- email.to,
               do: email
             )

    assert rescheduled.html_body =~ @meet_url
    assert rescheduled.text_body =~ @meet_url
    refute rescheduled.text_body =~ @space_url
  end

  # The booking's event, written and synced without a Meet, is asked for one
  # in place once the booking moves onto Meet; the booking then leaves Meet
  # before its video job takes the Meet and before a sync brings it back. The
  # cached event carries the request, so the move off takes the Meet off the
  # guest's event.
  test "a booking moved off Meet before taking the Meet asked for on its event takes it off",
       %{meeting: meeting} do
    use_runtime_calendar()
    GoogleMeetFake.start()

    set_video = fn video_integration_id, location ->
      MeetingSchema
      |> Repo.get!(meeting.id)
      |> Changeset.change(video_integration_id: video_integration_id, location: location)
      |> Repo.update!()
    end

    set_video.(nil, "Our office")
    run_calendar_jobs()
    %{provider_event_id: event_id} = written = Repo.get!(MeetingSchema, meeting.id)

    insert(:provider_calendar_event,
      calendar_integration: Repo.get!(CalendarIntegrationSchema, written.calendar_integration_id),
      uid: event_id,
      provider_event_id: event_id,
      provider_calendar_id: @calendar_id,
      provider_metadata: %{"id" => event_id}
    )

    set_video.(meeting.video_integration_id, nil)
    assert :ok = Meetings.request_event_conference(meeting.id, event_id)

    set_video.(nil, "Our office")
    assert :ok = CalendarEventSync.update(meeting.id, 1)

    assert [_create, {:put, _request_uri, request}, {:put, removal_uri, removal}] =
             for(
               {method, _uri, _body} = req <- GoogleMeetFake.requests(),
               method != :get,
               do: req
             )

    assert %{"createRequest" => _request} = request["conferenceData"]
    assert removal_uri.path =~ "/events/#{event_id}"
    assert URI.decode_query(removal_uri.query)["conferenceDataVersion"] == "1"
    refute Map.has_key?(removal, "conferenceData")
  end

  # The cache write-through runs in the same transaction, and a database
  # failure there aborts it: the job gets the error to retry, not a crash.
  test "a transaction aborted while the Meet is taken off returns its error", %{
    meeting: meeting
  } do
    use_runtime_calendar()
    GoogleMeetFake.start()

    original = book_onto_meet_then_move_off(meeting)

    insert(:provider_calendar_event,
      calendar_integration:
        Repo.get!(CalendarIntegrationSchema, original.calendar_integration_id),
      uid: original.provider_event_id,
      provider_event_id: original.provider_event_id,
      provider_calendar_id: @calendar_id
    )

    Repo.query!("""
    CREATE FUNCTION fail_cached_event_update() RETURNS trigger AS $$
    BEGIN RAISE EXCEPTION 'provider_calendar_events unavailable'; END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER fail_cached_event_update BEFORE UPDATE ON provider_calendar_events
    FOR EACH ROW EXECUTE FUNCTION fail_cached_event_update()
    """)

    assert {:error, :rollback} =
             CalendarEventSync.replace(meeting.id, original.provider_event_id, 1)
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

  # The booking's event is written with its Meet and the booking takes it;
  # then the booking leaves Meet. Returns the booking as it was on the Meet,
  # with every Google request so far already collected.
  defp book_onto_meet_then_move_off(meeting) do
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
    original
  end
end
