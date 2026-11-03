defmodule TymeslotWeb.Live.Themes.DefaultPagesJourneyTest do
  @moduledoc """
  A theme that writes only a page shell: a booker cancels, keeps and
  reschedules a meeting through the default pages, on the fixture theme.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes
  @moduletag :bookings
  @moduletag :integration

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    TestMocks.setup_all_mocks()

    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: "shellhost",
        booking_theme: "99",
        timezone: "Etc/UTC"
      )

    meeting =
      insert(:meeting,
        organizer_user: user,
        organizer_user_id: user.id,
        organizer_name: user.name,
        attendee_timezone: "Etc/UTC",
        status: :confirmed
      )

    %{profile: profile, meeting: meeting}
  end

  @tag :capture_log
  test "cancelling lands on the default cancel-confirmed page", %{
    conn: conn,
    profile: p,
    meeting: m
  } do
    {:ok, view, html} = live(conn, "/#{p.username}/meeting/#{m.uid}/cancel")
    assert html =~ ~s(data-testid="fixture-page-shell")

    {:error, {:redirect, %{to: to}}} =
      view |> element("[data-testid='cancel-meeting']") |> render_click()

    assert to == "/#{p.username}/meeting/#{m.uid}/cancel-confirmed"

    {:ok, _view, confirmed} = live(conn, to)
    assert confirmed =~ ~s(data-page="cancel_confirmed")
    assert confirmed =~ "Meeting Cancelled"
    assert Repo.get!(MeetingSchema, m.id).status == :cancelled
  end

  @tag :capture_log
  test "cancelling emails the cancellation to both the host and the attendee", %{
    conn: conn,
    profile: p,
    meeting: m
  } do
    # The real emails, rendered and handed to the Swoosh test adapter.
    stub_with(Tymeslot.EmailServiceMock, Tymeslot.Emails.EmailService)
    Application.put_env(:swoosh, :shared_test_process, self())
    on_exit(fn -> Application.delete_env(:swoosh, :shared_test_process) end)

    {:ok, view, _html} = live(conn, "/#{p.username}/meeting/#{m.uid}/cancel")

    {:error, {:redirect, _redirect}} =
      view |> element("[data-testid='cancel-meeting']") |> render_click()

    assert %{failure: 0} = Oban.drain_queue(queue: :emails, with_recursion: true)

    host_email = m.organizer_email
    attendee_email = m.attendee_email

    assert_received {:email, %Swoosh.Email{to: [{_name, ^host_email}]} = to_host}
    assert_received {:email, %Swoosh.Email{to: [{_name, ^attendee_email}]} = to_attendee}
    refute_received {:email, _another}

    assert to_host.subject =~ ~r/^Meeting Cancelled - .+ with #{Regex.escape(m.attendee_name)}$/

    assert to_attendee.subject =~
             ~r/^Meeting Cancelled - .+ with #{Regex.escape(m.organizer_name)}$/
  end

  @tag :capture_log
  test "keeping the meeting shows the kept state and changes nothing", %{
    conn: conn,
    profile: p,
    meeting: m
  } do
    {:ok, view, _html} = live(conn, "/#{p.username}/meeting/#{m.uid}/cancel")

    kept = view |> element("[data-testid='keep-meeting']") |> render_click()
    assert kept =~ "Great! Your meeting is still scheduled as planned."
    refute kept =~ "Yes, Cancel Meeting"
    assert Repo.get!(MeetingSchema, m.id).status == :confirmed
  end

  @tag :capture_log
  test "the reschedule page leads into the booking flow for this meeting", %{
    conn: conn,
    profile: p,
    meeting: m
  } do
    {:ok, view, _html} = live(conn, "/#{p.username}/meeting/#{m.uid}/reschedule")

    assert {:error, {:live_redirect, %{to: to}}} =
             view |> element("[data-testid='reschedule-choose-time']") |> render_click()

    assert to == "/#{p.username}?reschedule_meeting_uid=#{m.uid}"
  end
end
