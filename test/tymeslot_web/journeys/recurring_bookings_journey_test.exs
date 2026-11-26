defmodule TymeslotWeb.Journeys.RecurringBookingsJourneyTest do
  @moduledoc """
  Recurring bookings as the people using them meet them, end to end: a
  booker books a series on the Quill page, gets one confirmation for all
  its sessions, moves one and cancels the rest; a paid package goes
  through Stripe Checkout and the host refunds one session from the
  dashboard; a group series joins sessions others already booked; a host
  approves a series request from the dashboard; and a clash is named
  before anything is booked.

  Mocked are the boundaries only: the calendar provider and Stripe. Emails
  are rendered by the real email service and delivered to this process.
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :scheduling
  @moduletag :live
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.AuthTestHelpers
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory
  import Tymeslot.JourneyFixtureHelpers, only: [seed_organiser: 3]

  alias Ecto.Changeset
  alias Plug.Test
  alias Tymeslot.BookingSeries.SeriesSchema
  alias Tymeslot.Infrastructure.AvailabilityCache

  alias Tymeslot.MeetingPayments.BookingPayments
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.PaidSeriesTestHelpers, as: Paid
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub
  alias Tymeslot.StripeStubResponses
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker
  alias TymeslotWeb.BookingDriver
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  @quill "1"
  @checkout_url "https://checkout.stripe.com/c/pay/cs_SERIES"
  @booker %{name: "Ada Lovelace", email: "ada@example.com"}

  @weekly [
    name: "Weekly Course",
    duration_minutes: 30,
    series_mode: :recurring,
    series_frequency: :weekly,
    series_interval: 1,
    series_min_occurrences: 4,
    series_max_occurrences: 4
  ]

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()

    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      meeting_payments_enabled: true
    )

    recaptcha = Application.get_env(:tymeslot, :recaptcha, [])
    Application.put_env(:tymeslot, :recaptcha, Keyword.put(recaptcha, :booking_enabled, false))

    TestMocks.setup_all_mocks()

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _context -> {:error, :no_integration} end)

    # The real email service, so the rendered emails reach this process.
    email_service = Application.get_env(:tymeslot, :email_service_module)
    Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:tymeslot, :recaptcha, recaptcha)
      Application.put_env(:tymeslot, :email_service_module, email_service)
      Application.delete_env(:swoosh, :shared_test_process)
    end)

    %{day: Date.add(Date.utc_today(), 1)}
  end

  defp organiser(username, type_attrs) do
    seed_organiser(@quill, username, types: [type_attrs])
  end

  # Opens the page, chooses the type, picks the first time on `day` and moves
  # on to the series moment, once its check has answered.
  defp to_series(conn, profile, day) do
    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=Etc/UTC")

    BookingDriver.choose_meeting_type(view, hd(BookingDriver.meeting_types(view)))
    {_iso, _time} = BookingDriver.pick_first_slot(view, on: Date.to_iso8601(day))
    BookingDriver.continue(view)
    render_async(view)

    view
  end

  defp at_nine(day, weeks_later),
    do: day |> Date.add(weeks_later * 7) |> DateTime.new!(~T[09:00:00], "Etc/UTC")

  defp occurrences(view, status) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find("[data-testid='series-occurrence'][data-status='#{status}']")
  end

  defp sessions(user) do
    Repo.all(
      from(m in MeetingSchema,
        where: m.organizer_user_id == ^user.id and not is_nil(m.series_id),
        order_by: m.series_position
      )
    )
  end

  defp statuses(user), do: Enum.map(sessions(user), & &1.status)

  # Runs every email job due, the series' announcement among them, and
  # returns the emails they sent.
  defp deliver_emails do
    Oban.drain_queue(queue: :emails, with_recursion: true)
    mailbox([])
  end

  defp mailbox(emails) do
    receive do
      {:email, email} -> mailbox([email | emails])
    after
      0 -> Enum.reverse(emails)
    end
  end

  defp to_booker(emails), do: Enum.filter(emails, &(&1.to == [{@booker.name, @booker.email}]))

  defp to_host(emails, user),
    do: Enum.filter(emails, fn email -> Enum.any?(email.to, &(elem(&1, 1) == user.email)) end)

  defp ics(email), do: Enum.find(email.attachments, &(&1.content_type == "text/calendar"))

  defp dashboard(conn, user) do
    user
    |> Changeset.change(onboarding_completed_at: DateTime.utc_now(:second))
    |> Repo.update!()

    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
    view
  end

  @tag :capture_log
  test "a client books a weekly course and manages it", %{conn: conn, day: day} do
    %{user: user, profile: profile} = organiser("weekly-course", @weekly)

    # The booker picks the first session and sees all four dates.
    view = to_series(conn, profile, day)
    assert length(occurrences(view, "available")) == 4

    BookingDriver.continue(view)
    assert BookingDriver.submit(view, @booker) =~ "4 sessions booked"

    assert statuses(user) == List.duplicate(:confirmed, 4)
    [_first, second | _rest] = sessions(user)
    series = Repo.get!(SeriesSchema, second.series_id)

    # One confirmation to the booker, listing every session, with one
    # calendar attachment holding them all.
    sent = deliver_emails()
    assert [confirmation] = to_booker(sent)
    assert [_host_copy] = to_host(sent, user)

    for position <- 1..4, do: assert(confirmation.text_body =~ "Session #{position} of 4")
    assert length(Regex.scan(~r/^BEGIN:VEVENT/m, ics(confirmation).data)) == 4

    # The booker moves the second session with its own reschedule link.
    {:ok, move, _html} =
      live(conn, "/#{profile.username}?timezone=Etc/UTC&reschedule_meeting_uid=#{second.uid}")

    BookingDriver.choose_meeting_type(move, hd(BookingDriver.meeting_types(move)))
    moved_day = Date.add(day, 8)
    {_iso, _time} = BookingDriver.pick_first_slot(move, on: Date.to_iso8601(moved_day))
    BookingDriver.continue(move)
    BookingDriver.submit(move, @booker)

    moved = Repo.get!(MeetingSchema, second.id)
    assert DateTime.to_date(moved.start_time) == moved_day
    assert moved.series_id == series.id
    assert length(sessions(user)) == 4
    mailbox([])

    # The series page shows the session at its new date.
    {:ok, page, _html} = live(conn, "/#{profile.username}/series/#{series.uid}")

    session_two = page |> element("#series-session-2 .series-list__when") |> render()

    assert session_two =~
             LocalizationHelpers.format_meeting_datetime_compact(moved.start_time, "Etc/UTC")

    refute session_two =~
             LocalizationHelpers.format_meeting_datetime_compact(second.start_time, "Etc/UTC")

    # "Cancel all remaining" calls off every session still to come, with
    # one email to the booker.
    page |> element("[data-testid='series-cancel-all']") |> render_click()
    page |> element("[data-testid='series-cancel-all-confirm']") |> render_click()

    assert statuses(user) == List.duplicate(:cancelled, 4)

    assert [_one] =
             all_enqueued(worker: EmailWorker, args: %{"action" => "send_series_cancellation"})

    assert all_enqueued(worker: EmailWorker, args: %{"action" => "send_cancellation_emails"}) ==
             []

    assert [cancellation] = to_booker(deliver_emails())
    assert cancellation.subject == "4 sessions cancelled"
  end

  @tag :capture_log
  test "a client pays for a five-session package", %{conn: conn, day: day} do
    %{user: user, profile: profile} =
      organiser("five-pack",
        name: "Five Pack",
        duration_minutes: 30,
        payment_required: true,
        price_cents: Paid.price_cents(),
        series_mode: :flexible,
        series_min_occurrences: 5,
        series_max_occurrences: 5
      )

    insert(:connect_account,
      user: user,
      stripe_account_id: Paid.account(),
      default_currency: "eur",
      charges_enabled: true
    )

    StripeStub.expect(
      :create_checkout_session,
      1,
      StripeFixtures.object("checkout_session_payment", %{
        "id" => Paid.session_id(),
        "url" => @checkout_url,
        "payment_intent" => "pi_SERIES"
      })
    )

    # The booker picks five times: the first, then four more.
    view = to_series(conn, profile, day)
    add_last_time_of_day(view, 0)
    for index <- 0..2, do: add_last_time_of_day(view, index, 1)
    assert length(occurrences(view, "available")) == 5

    BookingDriver.continue(view)

    view
    |> form("form[data-fact='attendee']", %{
      "booking" => %{"name" => @booker.name, "email" => @booker.email, "message" => ""}
    })
    |> render_submit()

    assert_redirect(view, @checkout_url, 5_000)
    assert statuses(user) == List.duplicate(:awaiting_payment, 5)

    assert [%{form: %{"line_items" => [%{"quantity" => "5"}]}, headers: headers}] =
             StripeStub.requests(:create_checkout_session)

    assert headers["stripe-account"] == Paid.account()

    # Stripe tells us the checkout completed.
    Paid.stub_charge_backfill()

    series_id = hd(sessions(user)).series_id
    event = Paid.completed_event("evt_FIVE", series_id, 5 * Paid.price_cents())
    assert :ok = CheckoutSessionCompleted.handle(event)

    assert statuses(user) == List.duplicate(:confirmed, 5)
    assert [confirmation] = to_booker(deliver_emails())
    for position <- 1..5, do: assert(confirmation.text_body =~ "Session #{position} of 5")

    # The host cancels one session from the dashboard, with the default
    # refund: that session's share of the payment.
    StripeStub.expect(:create_refund, 1, fn request ->
      assert request.form["amount"] == to_string(Paid.price_cents())
      StripeStubResponses.refund(request, "re_FIVE")
    end)

    [_first, second | _rest] = sessions(user)
    host_view = dashboard(conn, user)
    host_view |> element("#cancel-meeting-#{second.id}") |> render_click()
    host_view |> form("#cancel-meeting-form") |> render_submit()

    assert statuses(user) == [:confirmed, :cancelled, :confirmed, :confirmed, :confirmed]

    assert %{status: :partially_refunded, refunded_amount_cents: refunded} =
             BookingPayments.payment_for_series(series_id)

    assert refunded == Paid.price_cents()
  end

  @tag :capture_log
  test "a client joins a weekly group class for six weeks", %{conn: conn, day: day} do
    %{user: user, profile: profile, meeting_types: [type]} =
      organiser(
        "group-class",
        Keyword.merge(@weekly,
          name: "Group Class",
          max_participants: 4,
          series_min_occurrences: 6,
          series_max_occurrences: 6
        )
      )

    # Someone already has a seat in the third week's class.
    week_three =
      insert(:group_meeting,
        organizer_user_id: user.id,
        meeting_type_id: type.id,
        start_time: at_nine(day, 2),
        end_time: DateTime.add(at_nine(day, 2), 30, :minute),
        capacity: 4,
        status: :confirmed
      )

    insert(:participant, meeting: week_three, email: "grace@example.com")
    AvailabilityCache.clear_all()

    view = to_series(conn, profile, day)
    assert length(occurrences(view, "available")) == 6

    BookingDriver.continue(view)
    assert BookingDriver.submit(view, @booker) =~ "6 sessions booked"

    seats =
      Repo.all(
        from(p in ParticipantSchema,
          where: p.email == ^@booker.email,
          order_by: p.series_position
        )
      )

    assert Enum.map(seats, & &1.series_position) == Enum.to_list(1..6)
    assert Enum.at(seats, 2).meeting_id == week_three.id

    # The host sees two of the class's four seats taken in week 3.
    host_view = dashboard(conn, user)

    assert host_view
           |> element("#meetings-#{week_three.id} [data-testid='group-seats-badge']")
           |> render() =~ "2/4 seats taken"
  end

  @tag :capture_log
  test "a host approves a series request", %{conn: conn, day: day} do
    %{user: user, profile: profile} =
      organiser(
        "approval-course",
        Keyword.merge(@weekly, requires_approval: true, approval_window_hours: 48)
      )

    view = to_series(conn, profile, day)
    BookingDriver.continue(view)

    assert BookingDriver.submit(view, @booker) =~ "Your request for 4 sessions has been sent"
    assert statuses(user) == List.duplicate(:awaiting_approval, 4)

    # One request reaches the host for the whole series.
    assert [request] = to_host(deliver_emails(), user)
    assert request.subject =~ "4 sessions"

    # The host approves it from the dashboard.
    [_first, second | _rest] = sessions(user)
    host_view = dashboard(conn, user)
    render_click(element(host_view, "button", "Requests"))
    host_view |> element("#approve-request-#{second.id}") |> render_click()
    render_async(host_view)

    assert statuses(user) == List.duplicate(:confirmed, 4)

    sent = deliver_emails()
    assert [confirmation] = to_booker(sent)
    assert confirmation.subject =~ "4 sessions"
    assert [_host_copy] = to_host(sent, user)
  end

  @tag :capture_log
  test "a clash is shown before booking", %{conn: conn, day: day} do
    %{user: user, profile: profile} = organiser("clash-course", @weekly)

    insert(:meeting,
      organizer_user_id: user.id,
      start_time: at_nine(day, 2),
      end_time: DateTime.add(at_nine(day, 2), 30, :minute),
      status: :confirmed
    )

    view = to_series(conn, profile, day)

    assert [clash] = occurrences(view, "unavailable")
    assert Floki.attribute(clash, "id") == ["series-occurrence-3"]
    assert Floki.text(clash) =~ "Not available"
    assert has_element?(view, "[data-testid='series-unavailable']")
    assert has_element?(view, "#series-step [data-intent='continue'][disabled]")
    assert sessions(user) == []
  end

  # Opens the series picker, moves it `weeks_later` weeks on, and adds the
  # last free time of its `index`th day.
  defp add_last_time_of_day(view, index, weeks_later \\ 0) do
    view |> element("[data-testid='series-add']") |> render_click()
    render_async(view)

    for _week <- List.duplicate(:later, weeks_later) do
      view |> element("[data-testid='series-picker-later']") |> render_click()
      render_async(view)
    end

    days = attribute_values(view, "[data-testid='series-picker-day']", "data-date")

    view
    |> element("[data-testid='series-picker-day'][data-date='#{Enum.at(days, index)}']")
    |> render_click()

    starts = attribute_values(view, "[data-testid='series-picker-time']", "data-value")

    view
    |> element("[data-testid='series-picker-time'][data-value='#{List.last(starts)}']")
    |> render_click()

    render_async(view)
  end

  defp attribute_values(view, selector, attribute) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find(selector)
    |> Enum.flat_map(&Floki.attribute(&1, attribute))
  end
end
