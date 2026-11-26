defmodule TymeslotWeb.Live.Scheduling.GroupEmailVerificationJourneyTest do
  @moduledoc """
  A seat on a group meeting type that requires the booker to confirm their
  email address, end to end: the booker takes a spot on the public page, the
  link arrives by email, and what the booker does with it (confirm, disown,
  ignore) decides what the organiser and the slot's other attendees ever hear.

  Until a seat is confirmed it holds its place, so the public page offers one
  spot fewer, but nobody else learns of it: no email to the organiser or the
  other attendees, no line on the host's calendar event, no participant on
  the dashboard card.

  As in `EmailVerificationBookingJourneyTest`, the queued work is run, links
  are read from the emails the people received, and only the boundaries are
  mocked: the calendar provider (`Tymeslot.CalendarMock`). Emails go through
  the real email service into Swoosh's test adapter.

  Covered elsewhere and not repeated here: each domain transition on its own
  (`Tymeslot.Meetings.EmailVerificationSeatsTest`), the seat states the link
  page reads (`TymeslotWeb.BookingVerificationLiveTest`), and the one-to-one
  journeys (`TymeslotWeb.Live.Scheduling.EmailVerificationBookingJourneyTest`).
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integration
  @moduletag :bookings

  import Mox
  import Tymeslot.AuthTestHelpers, only: [log_in_user: 2]
  import Tymeslot.Factory
  import Tymeslot.JourneyFixtureHelpers, only: [first_value: 3, seed_organiser: 3]
  import Tymeslot.Test.ClockHelpers
  import Ecto.Query, only: [where: 2]

  alias Ecto.Changeset
  alias Plug.Test
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Meetings.Workers.EmailVerificationExpiryWorker
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.WebhookWorker
  alias TymeslotWeb.BookingDriver
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  @first %{name: "Ana Lima", email: "ana@example.com"}
  @second %{name: "Bea Costa", email: "bea@example.com"}

  # Three spots, and the page counts them once three or fewer are left, so
  # every slot shows its exact number of free spots.
  @capacity 3

  # Reminders are scheduled for later and stay put, since draining leaves
  # future jobs alone. Webhooks are asserted as enqueued rather than run.
  @queues [:calendar_events, :video_rooms, :emails]

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()
    TestMocks.setup_subscription_mocks()

    recaptcha = Application.get_env(:tymeslot, :recaptcha, [])
    Application.put_env(:tymeslot, :recaptcha, Keyword.put(recaptcha, :booking_enabled, false))

    email_service = Application.get_env(:tymeslot, :email_service_module)
    Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:tymeslot, :recaptcha, recaptcha)
      Application.put_env(:tymeslot, :email_service_module, email_service)
      Application.delete_env(:swoosh, :shared_test_process)
    end)

    test_pid = self()

    # Each calendar write reports the description it carried, which is where
    # a group event lists its attendees.
    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _context -> {:error, :no_integration} end)
    |> stub(:create_event, fn event_data, _context ->
      send(test_pid, {:calendar_create, event_data.description})
      {:ok, CreatedEvent.new("group-verification-event-uid")}
    end)
    |> stub(:update_event, fn _uid, event_data, _context ->
      send(test_pid, {:calendar_update, event_data.description})
      :ok
    end)
    |> stub(:delete_event, fn _uid, _context, _opts ->
      send(test_pid, :calendar_delete)
      :ok
    end)

    %{user: user, profile: profile} = seed("group-verify-#{System.unique_integer([:positive])}")
    date = Date.utc_today() |> Date.add(1) |> Date.to_iso8601()

    %{user: user, profile: profile, date: date, time: first_time(profile, date)}
  end

  @tag :capture_log
  test "first seat: book, confirm, the slot comes to life", ctx do
    slot = book(ctx, @first)
    assert slot.status == :awaiting_verification
    seat = seat(slot, @first)
    assert seat.email_verified_at == nil

    drain()
    assert [verification] = drain_mailbox()
    assert [{_name, "ana@example.com"}] = verification.to
    refute_received {:calendar_create, _description}
    refute_enqueued(worker: WebhookWorker)
    refute dashboard(ctx.user) =~ "Ana Lima"

    {:ok, verify_view, _html} = live(build_conn(), verify_path(verification))

    assert verify_view |> element("[data-testid='confirm-booking']") |> render_click() =~
             "Your booking is confirmed"

    assert_enqueued(worker: WebhookWorker, args: %{"event_type" => "meeting.created"})
    drain()

    assert Repo.reload!(slot).status == :confirmed
    assert Repo.reload!(seat).email_verified_at

    assert_received {:calendar_create, description}
    assert description =~ "Attendees (1):"
    assert description =~ "ana@example.com"

    emails = drain_mailbox()
    assert email_to(emails, "ana@example.com").subject =~ ~r/confirmed/i
    assert email_to(emails, ctx.user.email)
    assert length(emails) == 2

    html = dashboard(ctx.user)
    assert html =~ "1/#{@capacity} seats taken"
    assert html =~ "Ana Lima"
  end

  @tag :capture_log
  test "a held seat is invisible to the other attendee", ctx do
    {slot, _confirmation} = book_and_confirm(ctx, @first)
    assert_received {:calendar_create, description}
    assert description =~ "Attendees (1):"
    assert spots_left(ctx) == "2 spots left"

    # The first seat's own `meeting.created` stays queued, since webhooks are
    # never run here; the second seat must add nothing to it.
    webhooks = all_enqueued(worker: WebhookWorker)

    # The second booker takes a spot and never confirms it.
    assert book(ctx, @second).id == slot.id
    held = seat(slot, @second)
    assert held.email_verified_at == nil

    drain()
    assert [verification] = drain_mailbox()
    assert [{_name, "bea@example.com"}] = verification.to
    refute_received {:calendar_create, _description}
    refute_received {:calendar_update, _description}
    assert all_enqueued(worker: WebhookWorker) == webhooks

    html = dashboard(ctx.user)
    assert html =~ "1/#{@capacity} seats taken"
    assert html =~ "Ana Lima"
    refute html =~ "Bea Costa"

    # The held spot is still taken: the next visitor sees one fewer.
    assert spots_left(ctx) == "1 spot left"
  end

  @tag :capture_log
  test "an unconfirmed first seat voids its slot", ctx do
    slot = book(ctx, @first)
    seat = seat(slot, @first)
    assert spots_left(ctx) == "2 spots left"

    drain()
    assert [_verification] = drain_mailbox()

    assert [job] =
             all_enqueued(
               worker: EmailVerificationExpiryWorker,
               args: %{"participant_id" => seat.id}
             )

    freeze_clock(DateTime.add(seat.verification_deadline_at, 1, :second))
    assert :ok = perform_job(EmailVerificationExpiryWorker, job.args)

    assert Repo.reload!(slot).status == :expired
    assert Repo.reload!(seat).cancelled_at

    drain()
    assert drain_mailbox() == []
    refute_received {:calendar_create, _description}
    refute_received {:calendar_update, _description}
    refute_enqueued(worker: WebhookWorker)

    assert spots_left(ctx) == "#{@capacity} spots left"
  end

  @tag :capture_log
  test "the last confirmed attendee leaves while a seat is held", ctx do
    {slot, confirmation} = book_and_confirm(ctx, @first)

    _held_slot = book(ctx, @second)
    drain()
    assert [verification] = drain_mailbox()
    assert [{_name, "bea@example.com"}] = verification.to

    # Ana gives up her spot from her confirmation email's link: she was the
    # last confirmed attendee, so the meeting is off for the organiser, but
    # Bea's held seat keeps the slot, held for verification again.
    conn = post(build_conn(), cancel_path(confirmation))
    assert html_response(conn, 200) =~ "Spot cancelled"

    assert Repo.reload!(slot).status == :awaiting_verification
    drain()

    emails = drain_mailbox()
    assert email_to(emails, "ana@example.com")
    assert email_to(emails, ctx.user.email)

    refute Enum.any?(emails, fn email ->
             Enum.any?(email.to, &match?({_, "bea@example.com"}, &1))
           end)

    # Bea was never part of Ana's meeting, so she is told nothing, and her
    # link still offers to confirm, inside her own window. Confirming brings
    # the slot back to life with her as its first attendee.
    {:ok, verify_view, _html} = live(build_conn(), verify_path(verification))

    assert verify_view |> element("[data-testid='confirm-booking']") |> render_click() =~
             "Your booking is confirmed"

    assert Repo.reload!(slot).status == :confirmed
    assert_enqueued(worker: WebhookWorker, args: %{"event_type" => "meeting.created"})
  end

  @tag :capture_log
  test "a booker who did not make the seat booking releases it", ctx do
    slot = book(ctx, @first)
    seat = seat(slot, @first)

    drain()
    assert [verification] = drain_mailbox()

    {:ok, verify_view, _html} = live(build_conn(), verify_path(verification))
    html = verify_view |> element("[data-testid='release-booking']") |> render_click()
    assert html =~ "Booking cancelled"
    assert html =~ "The booking was cancelled and your place released."

    released = Repo.reload!(seat)
    assert released.cancelled_at
    assert released.email_verified_at == nil

    drain()
    assert drain_mailbox() == []
    refute_received {:calendar_create, _description}
    refute_received {:calendar_update, _description}
    refute_enqueued(worker: WebhookWorker)

    assert spots_left(ctx) == "#{@capacity} spots left"
  end

  # The page names the seat's own deadline, not the slot's: the slot's is its
  # latest held seat's, which can be later than a new booker's (a slot held
  # again keeps the latest deadline of the seats it still holds).
  @tag :capture_log
  test "a second held seat is told its own deadline", ctx do
    slot = book(ctx, @first)
    slot_deadline = DateTime.truncate(DateTime.add(DateTime.utc_now(), 2, :hour), :second)

    Repo.update_all(where(MeetingSchema, id: ^slot.id),
      set: [verification_deadline_at: slot_deadline]
    )

    {view, booked} = book_view(ctx, @second)
    assert booked.id == slot.id
    held = seat(slot, @second)
    assert DateTime.before?(held.verification_deadline_at, slot_deadline)
    assert Repo.reload!(slot).verification_deadline_at == slot_deadline

    html = view |> element("[data-testid='check-inbox']") |> render()

    assert html =~
             LocalizationHelpers.format_meeting_datetime(
               held.verification_deadline_at,
               held.timezone
             )

    refute html =~ LocalizationHelpers.format_meeting_datetime(slot_deadline, held.timezone)
  end

  # A slot whose first seat counted at once has no deadline of its own; a
  # held seat joining it must still be told when to confirm by.
  @tag :capture_log
  test "a held seat joining a slot that never was held is told its deadline", ctx do
    set_verification(ctx.user, false)
    {_view, slot} = book_view(ctx, @first)
    assert slot.status == :confirmed
    assert slot.verification_deadline_at == nil

    set_verification(ctx.user, true)
    {view, booked} = book_view(ctx, @second)
    assert booked.id == slot.id
    held = seat(slot, @second)
    assert held.email_verified_at == nil

    assert view |> element("[data-testid='check-inbox']") |> render() =~
             LocalizationHelpers.format_meeting_datetime(
               held.verification_deadline_at,
               held.timezone
             )
  end

  # -- helpers ---------------------------------------------------------------

  defp seed(username) do
    organiser =
      seed_organiser("1", username,
        types: [
          [
            name: "Workshop",
            duration_minutes: 30,
            max_participants: @capacity,
            last_spots_threshold: @capacity,
            requires_email_verification: true
          ]
        ]
      )

    # Subscribed to both events, so a webhook that should not fire would.
    insert(:webhook, user: organiser.user, events: ["meeting.created", "meeting.cancelled"])

    organiser
  end

  # The day's first time, read off the page, so every booking in a test lands
  # on the same slot and the spots read for it are that slot's.
  defp first_time(profile, date) do
    profile |> schedule(date) |> first_value("[data-fact='time']", "data-value")
  end

  defp schedule(profile, date) do
    {:ok, view, _html} = live(build_conn(), "/#{profile.username}/workshop")
    BookingDriver.pick_date(view, date)
    wait_until(fn -> has_element?(view, "[data-fact='time']") end)
    view
  end

  # What the public page says about the slot's free spots, to a new visitor.
  defp spots_left(%{profile: profile, date: date, time: time}) do
    profile
    |> schedule(date)
    |> element("[data-fact='time'][data-value='#{time}'] [data-testid='seat-badge']")
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.text()
    |> String.trim()
  end

  defp book(ctx, attendee) do
    {view, slot} = book_view(ctx, attendee)
    assert has_element?(view, "[data-testid='check-inbox']")
    slot
  end

  # Books a seat and returns the booking page, still on its last step, with
  # the slot.
  defp book_view(%{profile: profile, user: user, date: date, time: time}, attendee) do
    {:ok, view, _html} = live(build_conn(), "/#{profile.username}")
    BookingDriver.book(view, date: date, time: time, attendee: attendee)
    {view, Repo.get_by!(MeetingSchema, organizer_user_id: user.id)}
  end

  defp set_verification(user, required?) do
    MeetingTypeSchema
    |> where(user_id: ^user.id)
    |> Repo.update_all(set: [requires_email_verification: required?])
  end

  # Books a seat and confirms it through the emailed link. Returns the slot
  # and the seat's confirmation email, leaving the mailbox empty.
  defp book_and_confirm(ctx, attendee) do
    slot = book(ctx, attendee)
    drain()
    [verification] = drain_mailbox()

    {:ok, verify_view, _html} = live(build_conn(), verify_path(verification))
    verify_view |> element("[data-testid='confirm-booking']") |> render_click()
    drain()

    {Repo.reload!(slot), email_to(drain_mailbox(), attendee.email)}
  end

  defp seat(slot, %{email: email}),
    do: Repo.get_by!(ParticipantSchema, meeting_id: slot.id, email: email)

  defp dashboard(user) do
    user =
      user
      |> Changeset.change(onboarding_completed_at: DateTime.utc_now(:second))
      |> Repo.update!()

    conn = build_conn() |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
    render(view)
  end

  defp verify_path(email), do: link_in(email, ~r{/verify-booking/[^\s"'<>]+})
  defp cancel_path(email), do: link_in(email, ~r{/seat/[^\s"'<>/]+/cancel})

  defp link_in(email, pattern) do
    case Regex.run(pattern, email.text_body) do
      [path] -> path
      nil -> flunk("no #{inspect(pattern)} link in the email's text body:\n#{email.text_body}")
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
