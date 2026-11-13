defmodule TymeslotWeb.Live.Scheduling.EmailVerificationBookingJourneyTest do
  @moduledoc """
  A booking on a meeting type that requires the attendee to confirm their
  email address, end to end: the attendee books on the public page, the link
  arrives by email, and what the attendee does with it (confirm, disown,
  ignore, ask for it again) decides what everyone else ever hears.

  The unit tests stop at "the job was enqueued" or "the row moved"; these run
  the queued work, so what they assert is what each person actually ends up
  with. The link is always read from the email the attendee received, never
  signed here, so the journeys prove the email carries a working link.

  Mocked are the boundaries only: the calendar provider (`Tymeslot.CalendarMock`).
  Emails go through the real email service into Swoosh's test adapter.

  Covered elsewhere and not repeated here: the owner preview books without
  verification (`TymeslotWeb.Live.Scheduling.VerificationPreviewTest`, "owner
  preview skips verification"); each toggle disabled while the other setting
  is on, and the server refusing a forged toggle
  (`TymeslotWeb.Dashboard.MeetingTypeFormEmailVerificationTest`,
  `TymeslotWeb.Dashboard.MeetingTypeFormPaymentsTest`); the changeset rules
  themselves (`Tymeslot.MeetingTypes.EmailVerificationRuleTest`,
  `Tymeslot.MeetingTypes.GroupRulesSchemaTest`).
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integration
  @moduletag :bookings

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.DashboardTestHelpers, only: [setup_dashboard_user: 1]
  import Tymeslot.Factory
  import Tymeslot.JourneyFixtureHelpers, only: [seed_organiser: 3]
  import Tymeslot.Test.ClockHelpers

  alias Tymeslot.DataCase
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.EmailVerification
  alias Tymeslot.Meetings.EmailVerificationToken
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.Workers.EmailVerificationExpiryWorker
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.WebhookWorker
  alias TymeslotWeb.BookingDriver
  alias TymeslotWeb.ThemeTestMatrix

  @attendee %{name: "Ana Lima", email: "ana@example.com"}
  @second_attendee %{name: "Bea Costa", email: "bea@example.com"}

  # The queues a booking's work runs on; reminders are scheduled for later and
  # stay put, since draining leaves future jobs alone. Webhooks are asserted as
  # enqueued rather than run, since running them would call out.
  @queues [:calendar_events, :video_rooms, :emails]

  @organiser_filters ["upcoming", "past", "cancelled", "awaiting_approval", "all"]

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

    test_pid = self()

    # Each calendar write reports the status it carried, so a test sees
    # whether the host's calendar heard of the booking at all.
    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _context -> {:error, :no_integration} end)
    |> stub(:create_event, fn event_data, _context ->
      send(test_pid, {:calendar_create, event_data.status})
      {:ok, CreatedEvent.new("verification-event-uid")}
    end)
    |> stub(:update_event, fn _uid, event_data, _context ->
      send(test_pid, {:calendar_update, event_data.status})
      :ok
    end)

    :ok
  end

  for theme <- ThemeTestMatrix.all() do
    describe "#{theme.name}" do
      @tag :capture_log
      test "book, confirm by email, the organiser is told", %{conn: conn} do
        %{user: user, profile: profile} =
          seed(unquote(theme.id), "verify-journey-#{unquote(theme.slug)}")

        # Step 1: the attendee books and is asked to check their inbox.
        {:ok, view, _html} = live(conn, "/#{profile.username}")
        BookingDriver.book(view, attendee: @attendee)

        assert has_element?(view, "[data-testid='check-inbox']")
        held = Repo.get_by!(MeetingSchema, organizer_user_id: user.id)
        assert held.status == :awaiting_verification

        # Step 2: the booking's work runs. Only the attendee hears of it.
        drain()

        assert [verification] = drain_mailbox()
        assert [{_name, "ana@example.com"}] = verification.to
        assert verification.subject =~ "Confirm your booking with"
        refute_received {:calendar_create, _status}
        refute_enqueued(worker: WebhookWorker)

        # Step 3: following the link without confirming changes nothing, as a
        # mail scanner's visit must not.
        {:ok, verify_view, _html} = live(build_conn(), verify_path(verification))
        assert has_element?(verify_view, "[data-testid='confirm-booking']")

        drain()
        assert Repo.reload!(held) == held
        assert drain_mailbox() == []
        refute_received {:calendar_create, _status}
        refute_enqueued(worker: WebhookWorker)

        # Step 4: the attendee confirms; the booking proceeds as an ungated
        # one would have.
        assert verify_view |> element("[data-testid='confirm-booking']") |> render_click() =~
                 "Your booking is confirmed"

        assert_enqueued(worker: WebhookWorker, args: %{"event_type" => "meeting.created"})
        drain()

        confirmed = Repo.reload!(held)
        assert confirmed.status == :confirmed
        assert confirmed.email_verified_at
        assert_received {:calendar_create, _status}

        emails = drain_mailbox()
        attendee_email = email_to(emails, "ana@example.com")
        assert attendee_email.subject =~ ~r/confirmed/i
        assert Enum.any?(attendee_email.attachments, &String.ends_with?(&1.filename, ".ics"))
        assert email_to(emails, user.email)

        assert confirmed.id in listed(user, "upcoming")
      end
    end
  end

  @tag :capture_log
  test "book and never confirm: the slot is released and nobody hears of it", %{conn: conn} do
    %{user: user, profile: profile} = seed("1", "verify-lapse")
    held = book(conn, profile, user, date: tomorrow())

    drain()
    assert [_verification] = drain_mailbox()

    # The hold lapses: the clock moves past the deadline and the expiry job
    # that was scheduled with the booking runs.
    assert [job] = all_enqueued(worker: EmailVerificationExpiryWorker)
    freeze_clock(DateTime.add(held.verification_deadline_at, 1, :second))
    assert :ok = perform_job(EmailVerificationExpiryWorker, job.args)

    expired = Repo.reload!(held)
    assert expired.status == :expired

    drain()
    assert drain_mailbox() == []
    refute_received {:calendar_create, _status}
    refute_received {:calendar_update, _status}
    refute_enqueued(worker: WebhookWorker)

    # The same slot is offered again, and taking it succeeds.
    rebooked = rebook(conn, profile, held)

    # Once the new booking is confirmed the organiser's surfaces show it,
    # and still not the one that lapsed.
    {:ok, :verified, _confirmed} = EmailVerification.verify(rebooked)
    assert_never_shown_to_organiser(user, expired, rebooked)
  end

  @tag :capture_log
  test "\"I didn't make this booking\" releases the slot silently", %{conn: conn} do
    %{user: user, profile: profile} = seed("1", "verify-disown")
    held = book(conn, profile, user, date: tomorrow())

    drain()
    assert [verification] = drain_mailbox()

    {:ok, verify_view, _html} = live(build_conn(), verify_path(verification))

    assert verify_view |> element("[data-testid='release-booking']") |> render_click() =~
             "Booking cancelled"

    released = Repo.reload!(held)
    assert released.status == :cancelled
    assert released.email_verified_at == nil

    drain()
    assert drain_mailbox() == []
    refute_received {:calendar_create, _status}
    refute_received {:calendar_update, _status}
    refute_enqueued(worker: WebhookWorker)

    rebooked = rebook(conn, profile, held)
    {:ok, :verified, _confirmed} = EmailVerification.verify(rebooked)
    assert_never_shown_to_organiser(user, released, rebooked)
  end

  @tag :capture_log
  test "resend sends the same working link again", %{conn: conn} do
    %{user: user, profile: profile} = seed("1", "verify-resend-journey")

    {:ok, view, _html} = live(conn, "/#{profile.username}")
    BookingDriver.book(view, date: tomorrow(), attendee: @attendee)
    held = Repo.get_by!(MeetingSchema, organizer_user_id: user.id)

    # The page and the email name the deadline itself, date and time in the
    # attendee's timezone, rather than a fixed length of time.
    deadline =
      held.verification_deadline_at
      |> DateTime.shift_zone!(held.attendee_timezone)
      |> Calendar.strftime("%-d %B %Y at %I:%M %p")

    assert has_element?(view, "[data-testid='check-inbox']", "by #{deadline}")

    drain()
    assert [first] = drain_mailbox()

    # Five minutes on, the attendee asks again: the email still names the
    # deadline set at booking, not five minutes later.
    freeze_clock(DateTime.add(DateTime.utc_now(:second), 5, :minute))
    view |> element("[data-testid='resend-verification']") |> render_click()

    drain()
    assert [second] = drain_mailbox()
    assert [{_name, "ana@example.com"}] = second.to
    assert second.subject == first.subject

    assert first.text_body =~ "by #{deadline}"
    assert second.text_body =~ "by #{deadline}"

    # Resending never extends the hold.
    resent = Repo.reload!(held)
    assert resent.verification_emails_sent == 2
    assert resent.verification_deadline_at == held.verification_deadline_at

    # Both links name the same booking at the same deadline, so either works.
    first_path = verify_path(first)
    second_path = verify_path(second)

    for path <- [first_path, second_path] do
      assert {:ok, %MeetingSchema{id: id}} =
               path
               |> String.replace_prefix("/verify-booking/", "")
               |> EmailVerificationToken.verify()

      assert id == held.id
    end

    {:ok, first_view, _html} = live(build_conn(), first_path)
    {:ok, second_view, _html} = live(build_conn(), second_path)
    assert has_element?(first_view, "[data-testid='confirm-booking']")
    assert has_element?(second_view, "[data-testid='confirm-booking']")

    # The newer link confirms; the older one then reads as already confirmed,
    # not as out of date.
    assert second_view |> element("[data-testid='confirm-booking']") |> render_click() =~
             "Your booking is confirmed"

    assert first_view |> element("[data-testid='confirm-booking']") |> render_click() =~
             "This booking is already confirmed"

    confirmed = Repo.reload!(held)
    assert confirmed.status == :confirmed
    assert confirmed.verification_deadline_at == held.verification_deadline_at

    drain()
    assert_received {:calendar_create, _status}
    refute_received {:calendar_create, _status}
  end

  @tag :capture_log
  test "confirming a booking that also needs approval sends the request", %{conn: conn} do
    %{user: user, profile: profile} =
      seed("1", "verify-approval", requires_approval: true, approval_window_hours: 24)

    booked_at = DateTime.utc_now(:second)
    freeze_clock(booked_at)

    {:ok, view, _html} = live(conn, "/#{profile.username}")
    html = BookingDriver.book(view, date: tomorrow(), attendee: @attendee)

    assert has_element?(view, "[data-testid='check-inbox']")
    refute html =~ "your request has been sent"

    held = Repo.get_by!(MeetingSchema, organizer_user_id: user.id)
    assert held.status == :awaiting_verification
    assert held.approval_requested_at == nil

    drain()
    assert [verification] = drain_mailbox()
    refute_received {:calendar_create, _status}

    # Ten minutes on, the attendee confirms: only now is the host asked.
    confirmed_at = DateTime.add(booked_at, 10, :minute)
    freeze_clock(confirmed_at)

    {:ok, verify_view, _html} = live(build_conn(), verify_path(verification))

    assert verify_view |> element("[data-testid='confirm-booking']") |> render_click() =~
             "Your request has been sent"

    requested = Repo.reload!(held)
    assert requested.status == :awaiting_approval
    assert requested.approval_requested_at == confirmed_at

    drain()
    assert_received {:calendar_create, :tentative}

    emails = drain_mailbox()
    assert email_to(emails, user.email).html_body =~ "/meeting-request/"
    assert email_to(emails, "ana@example.com")
  end

  # The form and the domain separately are covered by the modules named in the
  # moduledoc; this joins them: what the editor saves, the domain then guards.
  test "the toggle cannot be combined with payment or group bookings", %{conn: conn} do
    {:ok, dashboard} = setup_dashboard_user(%{conn: conn})
    {conn, user} = {dashboard[:conn], dashboard[:user]}
    meeting_type = insert(:meeting_type, user: user)

    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    view
    |> element("button[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
    |> render_click()

    view |> element("[data-testid='requires-email-verification-toggle']") |> render_click()

    saved = MeetingTypes.get_meeting_type(meeting_type.id, user.id)
    assert saved.requires_email_verification

    assert {:error, paid} =
             MeetingTypes.update_meeting_type(saved, %{payment_required: true, price_cents: 2500})

    assert DataCase.errors_on(paid)[:requires_email_verification]

    assert {:error, group} = MeetingTypes.update_meeting_type(saved, %{max_participants: 3})

    assert "group bookings cannot require email confirmation" in DataCase.errors_on(group).max_participants

    unchanged = MeetingTypes.get_meeting_type(meeting_type.id, user.id)
    refute unchanged.payment_required
    assert unchanged.max_participants in [nil, 1]
  end

  # -- helpers ---------------------------------------------------------------

  defp seed(theme_id, username, type_attrs \\ []) do
    organiser =
      seed_organiser(theme_id, username,
        types: [
          [name: "Quick Chat", duration_minutes: 30, requires_email_verification: true] ++
            type_attrs
        ]
      )

    # Subscribed to both events, so a webhook that should not fire would.
    insert(:webhook, user: organiser.user, events: ["meeting.created", "meeting.cancelled"])

    organiser
  end

  defp tomorrow, do: Date.utc_today() |> Date.add(1) |> Date.to_iso8601()

  defp book(conn, profile, user, opts) do
    {:ok, view, _html} = live(conn, "/#{profile.username}")
    BookingDriver.book(view, Keyword.put(opts, :attendee, @attendee))
    Repo.get_by!(MeetingSchema, organizer_user_id: user.id)
  end

  # Books the first free time on the released booking's day: it is the
  # released booking's own time only if the release gave it back.
  defp rebook(conn, profile, released) do
    {:ok, view, _html} = live(conn, "/#{profile.username}")

    BookingDriver.book(view,
      date: released.start_time |> DateTime.to_date() |> Date.to_iso8601(),
      attendee: @second_attendee
    )

    rebooked =
      Repo.one!(
        from m in MeetingSchema,
          where: m.organizer_user_id == ^released.organizer_user_id and m.id != ^released.id
      )

    assert rebooked.start_time == released.start_time
    assert rebooked.status == :awaiting_verification
    rebooked
  end

  defp assert_never_shown_to_organiser(user, hidden, shown) do
    listed_by_filter = Map.new(@organiser_filters, &{&1, listed(user, &1)})

    assert shown.id in listed_by_filter["upcoming"]

    for {filter, ids} <- listed_by_filter do
      refute hidden.id in ids, "the #{filter} list shows a booking the organiser never had"
    end

    from = DateTime.add(hidden.start_time, -1, :day)
    to = DateTime.add(hidden.start_time, 1, :day)

    in_grid =
      user.id |> Meetings.list_meetings_in_range_for_organizer(from, to) |> Enum.map(& &1.id)

    assert in_grid == [shown.id]

    now = DateTime.utc_now()

    assert Meetings.count_bookings(
             user.id,
             DateTime.add(now, -1, :hour),
             DateTime.add(now, 1, :hour)
           ) ==
             1
  end

  defp listed(user, filter) do
    {:ok, page} = Meetings.list_user_meetings_by_filter(user.id, filter, per_page: 50)
    Enum.map(page.items, & &1.id)
  end

  defp verify_path(email) do
    case Regex.run(~r{/verify-booking/[^\s"'<>]+}, email.text_body) do
      [path] -> path
      nil -> flunk("no verification link in the email's text body:\n#{email.text_body}")
    end
  end

  # Runs the booking queues until a pass runs nothing, since one job enqueues
  # the next.
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
