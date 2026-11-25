defmodule Tymeslot.Test.GoogleMeetBooking do
  @moduledoc """
  A host whose Google Calendar and Google Meet integration are the same
  Google account, and the steps a test walks a booking of theirs through:
  the public booking, the calendar job that writes the booking's Google
  event, and the video job that gives the booking its Meet link, all
  through the real Google Calendar client with Google played by
  `Tymeslot.Test.GoogleMeetFake`.
  """

  import ExUnit.Assertions
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.Factory

  alias ExUnit.Callbacks
  alias Oban.Testing
  alias Tymeslot.Bookings.Orchestrator
  alias Tymeslot.Emails.EmailService
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI
  alias Tymeslot.Integrations.Calendar.Runtime.Operations
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Test.GoogleMeetFake
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.{CalendarEventWorker, VideoRoomWorker}

  @account_id "google-sub-organiser"
  @calendar_id GoogleMeetFake.calendar_id()
  @meet_url GoogleMeetFake.meet_url()

  @doc """
  The host, their Meet integration, and a meeting type held on Meet. The
  calendar and email mocks are set up, with the booking recording the
  calendar its host's integrations really choose.
  """
  @spec meet_host() :: %{user: map(), meet: map(), meeting_type: map()}
  def meet_host do
    TestMocks.setup_calendar_mocks()
    TestMocks.setup_email_mocks()
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

    %{user: user, meet: meet, meeting_type: meeting_type}
  end

  @doc "Books `meeting_type`, asserting both of the booking's jobs were set off."
  @spec book(map(), map()) :: MeetingSchema.t()
  def book(user, meeting_type) do
    assert {:ok, booked} = submit(user, meeting_type)

    Testing.assert_enqueued(
      repo: Repo,
      worker: VideoRoomWorker,
      args: %{"meeting_id" => booked.id}
    )

    Testing.assert_enqueued(
      repo: Repo,
      worker: CalendarEventWorker,
      args: %{"meeting_id" => booked.id, "action" => "create"}
    )

    booked
  end

  @doc """
  Submits a public booking of `meeting_type` two days out at `time`, with
  `extra` merged into its meeting params.
  """
  @spec submit(map(), map(), String.t(), map()) :: {:ok, MeetingSchema.t()} | {:error, term()}
  def submit(user, meeting_type, time \\ "14:00", extra \\ %{}) do
    params = %{
      form_data: %{"name" => "Ada Attendee", "email" => "ada@example.com", "message" => ""},
      meeting_params:
        Map.merge(
          %{
            date: Date.add(Date.utc_today(), 2),
            time: time,
            duration: "30min",
            user_timezone: "Europe/London",
            organizer_user_id: user.id,
            meeting_type_id: meeting_type.id,
            with_video_room: true
          },
          extra
        )
    }

    Orchestrator.submit_booking(params, organizer_user_id: user.id)
  end

  @doc """
  Asserts the booking's one Google event carries the Meet Google made on it,
  and the booking took it as its room: no Meet space was made, and the only
  write was the event's create, asking for its Meet.
  """
  @spec assert_one_event_carrying_the_meet(MeetingSchema.t()) :: true
  def assert_one_event_carrying_the_meet(meeting) do
    requests = GoogleMeetFake.requests()

    # A POST to the Meet API would be a standalone Meet space, the room that
    # Google Calendar later replaces with a second link.
    assert for({_method, %URI{host: "meet.googleapis.com"} = uri, _body} <- requests, do: uri) ==
             []

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

  @doc """
  Asserts a write in place at `conferenceDataVersion=1` asking Google for a
  Meet, with a request the booking's later moves recognise as its own.
  """
  @spec assert_booking_meet_request(URI.t(), map()) :: true
  def assert_booking_meet_request(uri, body) do
    assert URI.decode_query(uri.query)["conferenceDataVersion"] == "1"

    assert %{
             "createRequest" => %{
               "requestId" => "tymeslot-booking-" <> _request,
               "conferenceSolutionKey" => %{"type" => "hangoutsMeet"}
             }
           } = body["conferenceData"]
  end

  @doc "Runs every queued calendar job, asserting none failed."
  @spec run_calendar_jobs() :: map()
  def run_calendar_jobs do
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :calendar_events)
  end

  @doc "Runs the booking's video job once, owing its announcement."
  @spec run_video_job(MeetingSchema.t()) :: term()
  def run_video_job(meeting) do
    Testing.perform_job(
      VideoRoomWorker,
      %{"meeting_id" => meeting.id, "announce" => true},
      repo: Repo
    )
  end

  @doc """
  Runs the queued video jobs and every job they hand over to, until the
  booking's room job is done: a job that asks the booking's event for its
  Meet hands over to a fresh copy of itself, which takes the Meet once
  Google has made it.
  """
  @spec run_video_jobs(MeetingSchema.t()) :: true
  def run_video_jobs(meeting) do
    assert %{failure: 0, discard: 0} =
             Oban.drain_queue(queue: :video_rooms, with_scheduled: true, with_recursion: true)

    Testing.refute_enqueued(
      repo: Repo,
      worker: VideoRoomWorker,
      args: %{"meeting_id" => meeting.id}
    )
  end

  @doc """
  Swaps in the runtime calendar module and the real Google Calendar API
  application-wide, until the test exits.
  """
  @spec use_runtime_calendar() :: :ok
  def use_runtime_calendar do
    calendar_module = Application.get_env(:tymeslot, :calendar_module)
    google_api = Application.get_env(:tymeslot, :google_calendar_api_module)
    Application.put_env(:tymeslot, :calendar_module, Operations)
    Application.put_env(:tymeslot, :google_calendar_api_module, CalendarAPI)

    Callbacks.on_exit(fn ->
      Application.put_env(:tymeslot, :calendar_module, calendar_module)
      Application.put_env(:tymeslot, :google_calendar_api_module, google_api)
    end)
  end

  @doc """
  Sends emails through the real email service, delivered to the test
  process, until the test exits; `received_emails/0` collects them.
  """
  @spec use_real_emails() :: :ok
  def use_real_emails do
    email_service = Application.get_env(:tymeslot, :email_service_module)
    Application.put_env(:tymeslot, :email_service_module, EmailService)
    Application.put_env(:swoosh, :shared_test_process, self())

    Callbacks.on_exit(fn ->
      Application.put_env(:tymeslot, :email_service_module, email_service)
      Application.delete_env(:swoosh, :shared_test_process)
    end)
  end

  @doc "The emails delivered since the last call, oldest first, as `{:email, email}`."
  @spec received_emails() :: [{:email, Swoosh.Email.t()}]
  def received_emails do
    receive do
      {:email, _email} = received -> [received | received_emails()]
    after
      0 -> []
    end
  end
end
