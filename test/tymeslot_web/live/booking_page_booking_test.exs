defmodule TymeslotWeb.BookingPageBookingTest do
  use TymeslotWeb.LiveCase, async: false
  @moduletag :bookings
  @moduletag :scheduling

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.BookingPages
  alias Tymeslot.Emails.EmailService
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.Utils.UrlBuilder
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
    user = insert(:user)

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
    page = insert(:booking_page, profile: profile, slug: "einfachiso")
    audit = insert(:meeting_type, user: user, name: "ISO audit", duration_minutes: 30)
    :ok = BookingPages.set_meeting_type(page, audit.id, true)

    %{user: user, page: page}
  end

  @tag :capture_log
  test "a visitor books from the page's start page, and the booking records the page", %{
    conn: conn,
    user: user,
    page: page
  } do
    {:ok, view, _html} = live(conn, ~p"/joern/einfachiso?timezone=#{@timezone}")
    BookingDriver.book(view, attendee: attendee("page-booker@example.com"))

    meeting =
      Repo.get_by!(MeetingSchema,
        organizer_user_id: user.id,
        attendee_email: "page-booker@example.com"
      )

    assert meeting.booking_page_id == page.id
  end

  # A type's own link under the page (`/<username>/<page>/<type>`) books it
  # through the page.
  @tag :capture_log
  test "a visitor books from a type's link under the page", %{
    conn: conn,
    user: user,
    page: page
  } do
    {:ok, view, _html} = live(conn, ~p"/joern/einfachiso/iso-audit?timezone=#{@timezone}")
    BookingDriver.book(view, attendee: attendee("type-link-booker@example.com"))

    meeting =
      Repo.get_by!(MeetingSchema,
        organizer_user_id: user.id,
        attendee_email: "type-link-booker@example.com"
      )

    assert meeting.booking_page_id == page.id
  end

  @tag :capture_log
  test "a booking made under the username records no page", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/joern?timezone=#{@timezone}")
    BookingDriver.book(view, attendee: attendee("username-booker@example.com"))

    meeting =
      Repo.get_by!(MeetingSchema,
        organizer_user_id: user.id,
        attendee_email: "username-booker@example.com"
      )

    assert meeting.booking_page_id == nil
  end

  # Booked under the page, cancelled through the link every booking carries
  # (under the username), and the cancellation email leads back to the page.
  @tag :capture_log
  test "cancelling a page's booking emails a link back to the page", %{conn: conn, user: user} do
    Application.put_env(:tymeslot, :email_service_module, EmailService)
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:tymeslot, :email_service_module, Tymeslot.EmailServiceMock)
      Application.delete_env(:swoosh, :shared_test_process)
    end)

    {:ok, view, _html} = live(conn, ~p"/joern/einfachiso?timezone=#{@timezone}")
    BookingDriver.book(view, attendee: attendee("cancel-booker@example.com"))

    meeting =
      Repo.get_by!(MeetingSchema,
        organizer_user_id: user.id,
        attendee_email: "cancel-booker@example.com"
      )

    {:ok, cancel_view, _html} = live(conn, ~p"/joern/meeting/#{meeting.uid}/cancel")
    render_click(cancel_view, "cancel_meeting", %{})

    assert :ok =
             perform_job(EmailWorker, %{
               "action" => "send_cancellation_emails",
               "meeting_id" => meeting.id
             })

    attendee_email =
      Enum.find(collect_emails([]), fn email ->
        Enum.any?(email.to, fn {_name, address} -> address == "cancel-booker@example.com" end)
      end)

    assert attendee_email, "no cancellation email reached the attendee"
    assert attendee_email.html_body =~ UrlBuilder.booking_url("joern/einfachiso")
    refute attendee_email.html_body =~ ~s(href="#{UrlBuilder.booking_url("joern")}")
  end

  defp attendee(email),
    do: %{name: "Test Attendee", email: email, message: "Looking forward to our chat!"}

  defp collect_emails(acc) do
    receive do
      {:email, email} -> collect_emails([email | acc])
    after
      0 -> acc
    end
  end
end
