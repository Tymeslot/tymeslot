defmodule TymeslotWeb.Live.Themes.JourneyUrlTest do
  @moduledoc """
  A declared journey's address follows the booking's facts (spec, "URLs
  follow facts"): the meeting type moves it to the type's own path, the
  slot to `/book`, the booking to `/thank-you`, each replacing the history
  entry. The page's own patch enters nothing again, so nothing chosen is
  lost. The classic journey keeps the route the visit arrived on.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes
  @moduletag :integration

  import Mox
  import Tymeslot.Factory
  import Tymeslot.JourneyFixtureHelpers

  alias Tymeslot.CalendarMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver
  alias TymeslotWeb.BookingDriver.Page

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  defp ahead, do: Date.utc_today() |> Date.add(3) |> Date.to_iso8601()

  @tag :capture_log
  test "a continuous page moves its address with each fact", %{conn: conn} do
    %{profile: profile} = seed_organiser("96", "url-scroll")
    user = profile.username
    {:ok, view, _html} = live(conn, "/#{user}")

    BookingDriver.choose_meeting_type(view, "quick-chat")
    assert_patch(view, "/#{user}/quick-chat")

    {_day, time} = BookingDriver.pick_first_slot(view, on: ahead())
    assert_patch(view, "/#{user}/quick-chat/book")

    # The page's own patch entered nothing again: the time is still chosen.
    assert live_assigns(view).selected_time == time

    BookingDriver.submit(view, %{name: "Ana Silva", email: "ana-url@example.com"})
    await(view, "[data-testid='confirmation-heading']")
    assert_patch(view, "/#{user}/thank-you")
  end

  @tag :capture_log
  test "a paged journey of its own moves its address too, keeping the query", %{conn: conn} do
    %{profile: profile} = seed_organiser("93", "url-two")
    user = profile.username
    {:ok, view, _html} = live(conn, "/#{user}?timezone=Etc%2FUTC")

    BookingDriver.choose_meeting_type(view, "quick-chat")
    assert_patch(view, "/#{user}/quick-chat?timezone=Etc%2FUTC")

    BookingDriver.continue(view)
    BookingDriver.pick_first_slot(view, on: ahead())
    assert_patch(view, "/#{user}/quick-chat/book?timezone=Etc%2FUTC")
    assert has_element?(view, "#pick-step form[data-fact='attendee']")
  end

  @tag :capture_log
  test "a deep link's day and time leave the address once another time is picked",
       %{conn: conn} do
    %{profile: profile} = seed_organiser("93", "url-deep")
    user = profile.username

    {:ok, view, _html} =
      live(conn, "/#{user}/quick-chat/book?date=#{ahead()}&time=10:00%20AM&timezone=Etc%2FUTC")

    [other | _rest] = Page.attribute(view, "[data-fact='time']", "data-value") -- ["10:00 AM"]
    BookingDriver.pick_time(view, other)

    assert_patch(view, "/#{user}/quick-chat/book?timezone=Etc%2FUTC")
    assert live_assigns(view).selected_time == other
  end

  @tag :capture_log
  test "a restart after a reschedule takes the reschedule out of the address once, and raises nothing",
       %{conn: conn} do
    %{user: user, profile: profile, meeting_types: [meeting_type]} =
      seed_organiser("96", "url-restart")

    meeting = insert_meeting(user, meeting_type)

    {:ok, view, _html} =
      live(conn, "/#{profile.username}/quick-chat?reschedule_meeting_uid=#{meeting.uid}")

    BookingDriver.book(view, attendee: %{name: "Ana Silva", email: "ana-url@example.com"})

    # The restart abandons the reschedule and drops it from the address
    # (`ReschedulePin.drop_from_url/2`); `follow_url/1` sees the socket
    # already patching and adds no second patch.
    BookingDriver.restart(view)

    # The patch's handle_params recorded the address it landed on.
    assert Process.alive?(view.pid)
    refute live_assigns(view)[:reschedule_meeting_uid]
    refute live_assigns(view).journey_url =~ "reschedule"
  end

  test "a thank-you address with no booking behind it sends the visitor to the start",
       %{conn: conn} do
    %{profile: profile} = seed_organiser("96", "url-empty-thanks")
    user = profile.username

    assert {:error, {:live_redirect, %{to: to}}} =
             live(
               conn,
               "/#{user}/thank-you?timezone=Etc%2FUTC&name=Ana&email=ana-url%40example.com"
             )

    # The start keeps the page's own query and never the visitor's name or email.
    assert to == "/#{user}?timezone=Etc%2FUTC"
  end

  test "a classic thank-you address still shows the confirmation", %{conn: conn} do
    %{profile: profile} = seed_organiser("1", "url-quill-thanks")

    assert {:ok, view, _html} = live(conn, "/#{profile.username}/thank-you")
    assert live_assigns(view).current_state == :confirmation
  end

  @tag :capture_log
  test "a restart from a paged journey's thank-you address opens on the meeting types",
       %{conn: conn} do
    %{user: user, profile: profile, meeting_types: [meeting_type]} =
      seed_organiser("93", "url-two-thanks")

    meeting = insert_meeting(user, meeting_type)

    {:ok, view, _html} = live(conn, "/#{profile.username}/thank-you?meeting_uid=#{meeting.uid}")
    assert live_assigns(view).current_state == :confirmation

    BookingDriver.restart(view)

    # No meeting type is known, so the booking starts on the types, not on a
    # time screen with none chosen.
    assert live_assigns(view).current_state == :offer
    assert_patch(view, "/#{profile.username}")
  end

  @tag :capture_log
  test "after a restart from the thank-you address the language switch rebuilds the start",
       %{conn: conn} do
    %{user: user, profile: profile, meeting_types: [meeting_type]} =
      seed_organiser("96", "url-scroll-thanks")

    meeting = insert_meeting(user, meeting_type)

    {:ok, view, _html} = live(conn, "/#{profile.username}/thank-you?meeting_uid=#{meeting.uid}")
    BookingDriver.restart(view)

    view |> element("button[phx-click='toggle_language_dropdown']") |> render_click()

    assert {:error, {:redirect, %{to: to}}} =
             view
             |> element("button[phx-click='change_locale'][phx-value-locale='de']")
             |> render_click()

    assert URI.parse(to).path == "/#{profile.username}"
  end

  @tag :capture_log
  test "the classic journey keeps the route it arrived on, through the confirmation",
       %{conn: conn} do
    %{profile: profile} = seed_organiser("1", "url-quill")
    {:ok, view, _html} = live(conn, "/#{profile.username}")

    BookingDriver.book(view,
      meeting_type: "quick-chat",
      attendee: %{name: "Ana Silva", email: "ana-quill@example.com"}
    )

    await(view, "[data-testid='confirmation-heading']")

    assert live_assigns(view)[:journey_url] == nil
    assert live_assigns(view).request_path == "/#{profile.username}"
  end

  defp insert_meeting(user, meeting_type) do
    start = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)

    insert(:meeting,
      organizer_user_id: user.id,
      organizer_name: user.name,
      meeting_type_id: meeting_type.id,
      attendee_name: "Ana Silva",
      attendee_email: "ana-url@example.com",
      attendee_timezone: "Etc/UTC",
      start_time: start,
      end_time: DateTime.add(start, 30, :minute),
      duration: 30,
      status: :confirmed
    )
  end
end
