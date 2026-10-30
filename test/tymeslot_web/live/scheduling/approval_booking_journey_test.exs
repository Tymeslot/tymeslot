defmodule TymeslotWeb.Live.Scheduling.ApprovalBookingJourneyTest do
  @moduledoc """
  A booking on a meeting type that requires the host's approval, end to end:
  the attendee books on the public page, the host opens the link in the
  request email and approves, and the queued work runs.

  The unit tests stop at "the jobs were enqueued"; this one runs them, so what
  it asserts is what each person actually ends up with: the host's calendar
  holds a tentative event that approval turns into a confirmed one, the video
  room is created only once the host has said yes, and the attendee's
  confirmation email carries its join link.

  Mocked are the boundaries only: the calendar provider (`Tymeslot.CalendarMock`)
  and the HTTP client Google Meet's API is reached through. Emails go through
  the real email service into Swoosh's test adapter.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :bookings

  import Mox
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver

  @timezone "Etc/UTC"
  @meet_url "https://meet.google.com/apr-oval-abc"
  # The queues a booking's work runs on; reminders are scheduled for later and
  # stay put, since draining leaves future jobs alone.
  @queues [:calendar_events, :video_rooms, :emails]

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()
    TestMocks.setup_subscription_mocks()

    recaptcha = Application.get_env(:tymeslot, :recaptcha, [])
    Application.put_env(:tymeslot, :recaptcha, Keyword.put(recaptcha, :booking_enabled, false))

    # The real email service, so the emails the jobs send are the ones a
    # person would receive; Swoosh's test adapter hands them to this process.
    email_service = Application.get_env(:tymeslot, :email_service_module)
    Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:tymeslot, :recaptcha, recaptcha)
      Application.put_env(:tymeslot, :email_service_module, email_service)
      Application.delete_env(:swoosh, :shared_test_process)
    end)

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _context -> {:error, :no_integration} end)

    %{user: user, profile: profile} = seed_booking_account("1", "approval-journey", @timezone)

    test_pid = self()

    # Each calendar write reports the status it carried, so a test sees the
    # host's calendar go from a hold to a confirmed event. Approval pushes the
    # event again, and so does the room job once the link exists.
    Tymeslot.CalendarMock
    |> expect(:create_event, fn event_data, _context ->
      send(test_pid, {:calendar_create, event_data.status})
      {:ok, CreatedEvent.new("approval-event-uid")}
    end)
    |> stub(:update_event, fn _uid, event_data, _context ->
      send(test_pid, {:calendar_update, event_data.status})
      :ok
    end)

    meeting_type =
      user.id
      |> then(&Repo.get_by!(MeetingTypeSchema, user_id: &1))
      |> Changeset.change(requires_approval: true, approval_window_hours: 24)
      |> Repo.update!()

    %{user: user, profile: profile, meeting_type: meeting_type}
  end

  @tag :capture_log
  test "a request the host approves reaches the attendee as a confirmed booking with its room",
       %{conn: conn, user: user, profile: profile, meeting_type: meeting_type} do
    video =
      insert(:video_integration,
        user: user,
        name: "Google Meet",
        provider: "google_meet",
        oauth_scope: "https://www.googleapis.com/auth/meetings.space.created",
        token_expires_at: DateTime.add(DateTime.utc_now(:second), 3600)
      )

    meeting_type
    |> Changeset.change(allow_video: true, video_integration_id: video.id)
    |> Repo.update!()

    # Step 1: the attendee books on the public page.
    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{@timezone}")

    BookingDriver.book(view,
      attendee: %{name: "Grace Hopper", email: "grace@example.com", message: "Hello"}
    )

    meeting = Repo.get_by!(MeetingSchema, organizer_user_id: user.id)
    assert meeting.status == :awaiting_approval
    assert meeting.video_integration_id == video.id

    # Step 2: the request's work runs. No room may exist yet: nothing is
    # created at the provider for a booking the host may still decline.
    drain()

    assert_receive {:calendar_create, :tentative}
    assert Repo.reload!(meeting).video_room_id == nil

    request_emails = drain_mailbox()
    request_email = email_to(request_emails, user.email)
    [_match, token] = Regex.run(~r{/meeting-request/([^"'\s<]+)}, request_email.html_body)

    # The attendee was told their booking awaits the host, and was not sent a
    # join link: there is no room yet.
    attendee_notice = email_to(request_emails, "grace@example.com")
    refute attendee_notice.html_body =~ "meet.google.com"

    # Step 3: the host opens the link in the email and approves.
    {:ok, request_view, _html} = live(build_conn(), "/meeting-request/#{token}")

    assert request_view |> element("[data-testid='approve-request']") |> render_click() =~
             "Booking confirmed"

    # Step 4: the confirmation's work runs: the room first, then the emails.
    expect(HTTPClientMock, :request, fn :post, url, _body, _headers, _opts ->
      assert url =~ "meet.googleapis.com"
      space = %{"name" => "spaces/ApprovalSpace", "meetingUri" => @meet_url}
      {:ok, %Req.Response{status: 200, body: Jason.encode!(space)}}
    end)

    drain()

    confirmed = Repo.reload!(meeting)
    assert confirmed.status == :confirmed
    assert confirmed.video_room_id == "ApprovalSpace"
    assert confirmed.meeting_url == @meet_url
    assert confirmed.attendee_email_sent

    assert_received {:calendar_update, :confirmed}
    refute_received {:calendar_update, :tentative}

    attendee_email = email_to(drain_mailbox(), "grace@example.com")
    assert attendee_email.html_body =~ @meet_url
  end

  @tag :capture_log
  test "approving a request with no video room confirms the calendar event and emails the attendee",
       %{conn: conn, user: user, profile: profile} do
    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{@timezone}")
    BookingDriver.book(view, attendee: %{name: "Alan Turing", email: "alan@example.com"})

    meeting = Repo.get_by!(MeetingSchema, organizer_user_id: user.id)
    assert meeting.status == :awaiting_approval

    drain()
    assert_receive {:calendar_create, :tentative}

    request_email = email_to(drain_mailbox(), user.email)
    [_match, token] = Regex.run(~r{/meeting-request/([^"'\s<]+)}, request_email.html_body)

    {:ok, request_view, _html} = live(build_conn(), "/meeting-request/#{token}")
    request_view |> element("[data-testid='approve-request']") |> render_click()

    drain()

    # With no room job to push the event again, approval's own update is what
    # turns the host's tentative hold into a confirmed event.
    assert_received {:calendar_update, :confirmed}

    confirmed = Repo.reload!(meeting)
    assert confirmed.status == :confirmed
    assert confirmed.attendee_email_sent

    confirmation = email_to(drain_mailbox(), "alan@example.com")
    assert confirmation.subject =~ ~r/confirmed/i
  end

  # A type offering several lengths, requested at one that is not its own: the
  # hour asked for is the one the host approves, and the one the attendee's
  # confirmation states.
  @tag :capture_log
  test "a request at a length not the type's own keeps it through approval",
       %{conn: conn, user: user, profile: profile, meeting_type: meeting_type} do
    meeting_type |> Changeset.change(extra_lengths_minutes: [60]) |> Repo.update!()

    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{@timezone}")

    BookingDriver.book(view,
      meeting_type: "quick-chat",
      length: 60,
      attendee: %{name: "Ada Lovelace", email: "ada@example.com"}
    )

    requested = Repo.get_by!(MeetingSchema, organizer_user_id: user.id)
    assert requested.status == :awaiting_approval
    assert requested.duration == 60
    assert DateTime.diff(requested.end_time, requested.start_time, :minute) == 60

    drain()
    assert_receive {:calendar_create, :tentative}

    request_email = email_to(drain_mailbox(), user.email)
    [_match, token] = Regex.run(~r{/meeting-request/([^"'\s<]+)}, request_email.html_body)

    {:ok, request_view, _html} = live(build_conn(), "/meeting-request/#{token}")
    request_view |> element("[data-testid='approve-request']") |> render_click()

    drain()

    confirmed = Repo.reload!(requested)
    assert confirmed.status == :confirmed
    assert confirmed.duration == 60
    assert confirmed.start_time == requested.start_time
    assert confirmed.end_time == requested.end_time

    confirmation = email_to(drain_mailbox(), "ada@example.com")
    assert confirmation.subject =~ ~r/confirmed/i
    assert confirmation.text_body =~ "Duration: 1 hour"
    assert confirmation.html_body =~ "1 hour"

    # The calendar file the attendee adds ends at the hour's end.
    [ics] = Enum.filter(confirmation.attachments, &String.ends_with?(&1.filename, ".ics"))
    assert ics.data =~ "DTEND:#{Calendar.strftime(confirmed.end_time, "%Y%m%dT%H%M%SZ")}"
  end

  # -- helpers ---------------------------------------------------------------

  # Runs the booking queues until a pass runs nothing, since one job enqueues
  # the next (the room job sends the confirmation emails).
  defp drain do
    ran =
      Enum.reduce(@queues, 0, fn queue, acc ->
        %{success: success, failure: failure} =
          Oban.drain_queue(queue: queue, with_recursion: true)

        assert failure == 0, "a #{queue} job failed"
        acc + success
      end)

    if ran > 0, do: drain()
  end

  defp email_to(emails, address) do
    case Enum.find(emails, fn email -> Enum.any?(email.to, &match?({_, ^address}, &1)) end) do
      nil -> flunk("no email to #{address}; received: #{inspect(Enum.map(emails, & &1.to))}")
      email -> email
    end
  end

  defp drain_mailbox(acc \\ []) do
    receive do
      {:email, email} -> drain_mailbox([email | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
