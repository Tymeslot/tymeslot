defmodule TymeslotWeb.BookingPageAttributionJourneyTest do
  @moduledoc """
  A booking made through one of the host's booking pages, as the host sees
  it afterwards: tagged with the page and filterable by it in the dashboard's
  Meetings list, and named in the host's notification email but not the
  invitee's.
  """

  use TymeslotWeb.LiveCase, async: false
  @moduletag :bookings
  @moduletag :meetings

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.BookingPages
  alias Tymeslot.Emails.EmailService
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker
  alias TymeslotWeb.BookingDriver

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()
    :ok
  end

  @timezone "America/New_York"

  setup do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())

    profile =
      insert(:profile, user: user, username: "joern", booking_theme: "1", timezone: @timezone)

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_before_minutes: 0,
        buffer_after_minutes: 0
      )

    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end)

    insert(:calendar_integration, user: user, is_active: true)
    page = insert(:booking_page, profile: profile, slug: "einfachiso", name: "Einfach ISO")
    audit = insert(:meeting_type, user: user, name: "ISO audit", duration_minutes: 30)
    :ok = BookingPages.set_meeting_type(page, audit.id, true)

    %{user: user, page: page}
  end

  @tag :capture_log
  test "the host sees which page a booking came through and filters the list by page", %{
    conn: conn,
    user: user,
    page: page
  } do
    {:ok, view, _html} = live(conn, ~p"/joern/einfachiso?timezone=#{@timezone}")
    BookingDriver.book(view, attendee: attendee("Page Booker", "page-booker@example.com"))

    {:ok, view, _html} = live(conn, ~p"/joern?timezone=#{@timezone}")
    BookingDriver.book(view, attendee: attendee("Main Booker", "main-booker@example.com"))

    page_meeting = meeting_for(user, "page-booker@example.com")
    main_meeting = meeting_for(user, "main-booker@example.com")

    {:ok, dashboard, _html} = live(host_conn(user), ~p"/dashboard/meetings")
    render_async(dashboard)

    assert dashboard
           |> element("##{dom_id(page_meeting)} [data-testid='booking-page-tag']")
           |> render() =~ "via Einfach ISO"

    assert has_element?(dashboard, "##{dom_id(main_meeting)}")
    refute has_element?(dashboard, "##{dom_id(main_meeting)} [data-testid='booking-page-tag']")

    dashboard
    |> form("#meetings-page-filter")
    |> render_change(%{"page" => Integer.to_string(page.id)})

    assert has_element?(dashboard, "##{dom_id(page_meeting)}")
    refute has_element?(dashboard, "##{dom_id(main_meeting)}")

    dashboard |> form("#meetings-page-filter") |> render_change(%{"page" => "main"})

    assert has_element?(dashboard, "##{dom_id(main_meeting)}")
    refute has_element?(dashboard, "##{dom_id(page_meeting)}")

    dashboard |> form("#meetings-page-filter") |> render_change(%{"page" => "all"})

    assert has_element?(dashboard, "##{dom_id(main_meeting)}")
    assert has_element?(dashboard, "##{dom_id(page_meeting)}")
  end

  test "a host without booking pages is offered no page filter", %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    insert(:profile, user: user)

    {:ok, dashboard, _html} = live(host_conn(user, conn), ~p"/dashboard/meetings")

    refute has_element?(dashboard, "#meetings-page-filter")
  end

  test "a page deleted since leaves its bookings untagged", %{conn: conn, user: user, page: page} do
    meeting = upcoming_meeting(user, booking_page_id: page.id)
    {:ok, _deleted} = BookingPages.delete(page)

    {:ok, dashboard, _html} = live(host_conn(user, conn), ~p"/dashboard/meetings")

    assert has_element?(dashboard, "##{dom_id(meeting)}")
    refute has_element?(dashboard, "[data-testid='booking-page-tag']")
  end

  @tag :capture_log
  test "the host's confirmation names the page; the invitee's does not", %{
    conn: conn,
    user: user
  } do
    Application.put_env(:tymeslot, :email_service_module, EmailService)
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:tymeslot, :email_service_module, Tymeslot.EmailServiceMock)
      Application.delete_env(:swoosh, :shared_test_process)
    end)

    {:ok, view, _html} = live(conn, ~p"/joern/einfachiso?timezone=#{@timezone}")
    BookingDriver.book(view, attendee: attendee("Page Booker", "page-booker@example.com"))
    meeting = meeting_for(user, "page-booker@example.com")

    assert :ok =
             perform_job(EmailWorker, %{
               "action" => "send_confirmation_emails",
               "meeting_id" => meeting.id
             })

    emails = collect_emails([])
    host_email = Enum.find(emails, &addressed_to?(&1, meeting.organizer_email))
    invitee_email = Enum.find(emails, &addressed_to?(&1, "page-booker@example.com"))

    assert host_email, "no confirmation reached the host"
    assert invitee_email, "no confirmation reached the invitee"

    assert host_email.html_body =~ "Booked through your Einfach ISO page"
    assert host_email.text_body =~ "Booked through your Einfach ISO page"
    refute invitee_email.html_body =~ "Einfach ISO"
    refute invitee_email.text_body =~ "Einfach ISO"
  end

  defp host_conn(user, conn \\ build_conn()) do
    conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(user)
  end

  defp upcoming_meeting(user, attrs) do
    start = DateTime.add(DateTime.utc_now(), 2, :day)

    insert(
      :meeting,
      [
        organizer_user_id: user.id,
        organizer_email: user.email,
        start_time: start,
        end_time: DateTime.add(start, 30, :minute)
      ] ++ attrs
    )
  end

  defp meeting_for(user, attendee_email),
    do: Repo.get_by!(MeetingSchema, organizer_user_id: user.id, attendee_email: attendee_email)

  defp dom_id(meeting), do: "meetings-#{meeting.id}"

  defp attendee(name, email), do: %{name: name, email: email, message: "Looking forward to it"}

  defp addressed_to?(email, address),
    do: Enum.any?(email.to, fn {_name, to} -> to == address end)

  defp collect_emails(acc) do
    receive do
      {:email, email} -> collect_emails([email | acc])
    after
      0 -> acc
    end
  end
end
