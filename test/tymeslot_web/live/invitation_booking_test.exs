defmodule TymeslotWeb.InvitationBookingTest do
  @moduledoc """
  Booking an invitation-only meeting type through a personal invitation link:
  the entry gate on the type's own address, the prefilled form, the link
  being spent by the booking, and what stays open without a token (a
  reschedule, the host's preview).
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :bookings
  @moduletag :integration

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.BookingTestHelpers
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Invitations
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Profiles.ReservedPaths
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver
  alias TymeslotWeb.Live.Scheduling.InvitationMessages
  alias TymeslotWeb.Live.Scheduling.PreviewToken
  alias TymeslotWeb.Themes.Shared.PathHandlers

  @timezone "America/New_York"
  @username "invitedhost"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    old_cfg = Application.get_env(:tymeslot, :recaptcha, [])
    Application.put_env(:tymeslot, :recaptcha, Keyword.put(old_cfg, :booking_enabled, false))
    on_exit(fn -> Application.put_env(:tymeslot, :recaptcha, old_cfg) end)

    %{user: user, profile: profile} =
      BookingTestHelpers.seed_booking_account("1", @username, @timezone)

    type =
      insert(:meeting_type,
        user: user,
        name: "Coaching",
        slug: "coaching",
        duration_minutes: 30,
        is_active: true,
        invitation_only: true
      )

    {:ok, invitation} =
      Invitations.create(user.id, type, %{name: "Ada Lovelace", email: "ada@example.com"})

    %{user: user, profile: profile, type: type, invitation: invitation}
  end

  @tag :capture_log
  test "an invitation-only type without a token sends the visitor away", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/" <> @username, flash: %{"error" => message}}}} =
             live(conn, "/#{@username}/coaching?timezone=#{@timezone}")

    assert message == InvitationMessages.message(:required)
  end

  @tag :capture_log
  test "the booking step of an invitation-only type is gated too", %{conn: conn} do
    tomorrow = @timezone |> DateTime.now!() |> DateTime.to_date() |> Date.add(1)

    assert {:error, {:redirect, %{flash: %{"error" => message}}}} =
             live(conn, "/#{@username}/coaching/book?date=#{tomorrow}&time=10:00")

    assert message == InvitationMessages.message(:required)
  end

  @tag :capture_log
  test "a crafted invite param is no token", %{conn: conn} do
    assert {:error, {:redirect, %{flash: %{"error" => message}}}} =
             live(conn, "/#{@username}/coaching?invite[]=x&timezone=#{@timezone}")

    assert message == InvitationMessages.message(:required)
  end

  @tag :capture_log
  test "an invitation-only type is not reachable through the overview by its duration", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, "/#{@username}?duration=coaching&timezone=#{@timezone}")

    refute html =~ "Coaching"
    refute has_element?(view, "[data-fact='date']")
  end

  @tag :capture_log
  test "a valid token shows times and the form is prefilled", %{
    conn: conn,
    invitation: invitation
  } do
    view = open_invitation(conn, invitation)

    assert has_element?(view, "[data-fact='date']")

    BookingTestHelpers.walk_from_schedule_to_booking_form(view, @timezone)

    assert has_element?(view, "input[name='booking[name]'][value='Ada Lovelace']")
    assert has_element?(view, "input[name='booking[email]'][value='ada@example.com']")
  end

  @tag :capture_log
  test "submitting books once; the link then refuses", %{
    conn: conn,
    user: user,
    invitation: invitation
  } do
    view = open_invitation(conn, invitation)
    BookingTestHelpers.walk_from_schedule_to_booking_form(view, @timezone)

    # The prefilled fields stay editable.
    BookingDriver.submit(view, %{"name" => "Ada King"})
    wait_until(fn -> Repo.get_by(MeetingSchema, invitation_id: invitation.id) != nil end)

    meeting = Repo.get_by!(MeetingSchema, invitation_id: invitation.id)
    assert meeting.organizer_user_id == user.id
    assert meeting.attendee_name == "Ada King"
    assert meeting.attendee_email == "ada@example.com"

    assert {:error, {:redirect, %{flash: %{"error" => message}}}} =
             live(conn, invite_path(invitation))

    assert message == InvitationMessages.message(:used)
  end

  @tag :capture_log
  test "a token for another meeting type is refused", %{conn: conn, user: user} do
    other =
      insert(:meeting_type,
        user: user,
        name: "Mentoring",
        slug: "mentoring",
        is_active: true,
        invitation_only: true
      )

    {:ok, other_invitation} = Invitations.create(user.id, other, %{})

    assert {:error, {:redirect, %{flash: %{"error" => message}}}} =
             live(
               conn,
               "/#{@username}/coaching?invite=#{URI.encode_www_form(other_invitation.token)}"
             )

    assert message == InvitationMessages.message(:required)
  end

  @tag :capture_log
  test "the reschedule link works without a token", %{
    conn: conn,
    profile: profile,
    invitation: invitation
  } do
    view = open_invitation(conn, invitation)
    BookingTestHelpers.walk_from_schedule_to_booking_form(view, @timezone)
    BookingDriver.submit(view)
    wait_until(fn -> Repo.get_by(MeetingSchema, invitation_id: invitation.id) != nil end)

    meeting = Repo.get_by!(MeetingSchema, invitation_id: invitation.id)

    reschedule_path =
      PathHandlers.organizer_scheduling_path(%{
        organizer_profile: profile,
        meeting_uid: meeting.uid
      })

    refute reschedule_path =~ "invite="

    {:ok, reschedule, _html} = live(conn, reschedule_path <> "&timezone=#{@timezone}")
    BookingDriver.choose_meeting_type(reschedule, "coaching")
    BookingDriver.continue(reschedule)

    assert has_element?(reschedule, "[data-fact='date']")

    # A day after the booked one, so the move is to another time.
    later = @timezone |> DateTime.now!() |> DateTime.to_date() |> Date.add(2) |> Date.to_iso8601()
    BookingDriver.pick_first_slot(reschedule, on: later)
    BookingDriver.continue(reschedule)
    BookingDriver.submit(reschedule)

    wait_until(fn -> Repo.get!(MeetingSchema, meeting.id).start_time != meeting.start_time end)

    assert Repo.aggregate(MeetingSchema, :count, :id) == 1
  end

  @tag :capture_log
  test "the host preview of an invitation-only type is not gated", %{conn: conn, user: user} do
    query =
      URI.encode_query(%{
        "preview" => "true",
        "preview_token" => PreviewToken.sign(user.id),
        "timezone" => @timezone
      })

    {:ok, view, _html} = live(conn, "/#{@username}/coaching?#{query}")

    assert has_element?(view, "[data-fact='date']")

    BookingTestHelpers.walk_from_schedule_to_booking_form(view, @timezone)
    html = BookingDriver.submit(view, %{"name" => "Owner", "email" => "owner@example.com"})

    refute html =~ InvitationMessages.message(:required)
    assert has_element?(view, "[data-intent='restart']")
    assert Repo.aggregate(MeetingSchema, :count, :id) == 0
  end

  @tag :capture_log
  test "preview=true alone does not open an invitation-only type", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/" <> @username, flash: %{"error" => message}}}} =
             live(conn, "/#{@username}/coaching?preview=true&timezone=#{@timezone}")

    assert message == InvitationMessages.message(:required)
  end

  @tag :capture_log
  test "a preview token signed for another user does not open it", %{conn: conn, user: user} do
    stranger = insert(:user)
    refute stranger.id == user.id

    query =
      URI.encode_query(%{
        "preview" => "true",
        "preview_token" => PreviewToken.sign(stranger.id),
        "timezone" => @timezone
      })

    assert {:error, {:redirect, %{flash: %{"error" => message}}}} =
             live(conn, "/#{@username}/coaching?#{query}")

    assert message == InvitationMessages.message(:required)
  end

  @tag :capture_log
  test "scheduling another after the booking is refused: the link is spent", %{
    conn: conn,
    invitation: invitation
  } do
    view = open_invitation(conn, invitation)
    BookingTestHelpers.walk_from_schedule_to_booking_form(view, @timezone)
    BookingDriver.submit(view)
    wait_until(fn -> Repo.get_by(MeetingSchema, invitation_id: invitation.id) != nil end)
    wait_until(fn -> has_element?(view, "[data-intent='restart']") end)

    view |> element("[data-intent='restart']") |> render_click()

    {path, flash} = assert_redirect(view)
    assert path == "/" <> @username
    assert flash["error"] == InvitationMessages.message(:used)
  end

  @tag :capture_log
  test "switching language keeps the invitation, and the guest can still book", %{
    conn: conn,
    invitation: invitation
  } do
    view = open_invitation(conn, invitation)
    view |> element("button[phx-click='toggle_language_dropdown']") |> render_click()

    # The switch is a full redirect, so the page it lands on knows only what
    # the URL carries.
    {:ok, conn} =
      view
      |> element("button[phx-click='change_locale'][phx-value-locale='de']")
      |> render_click()
      |> follow_redirect(conn)

    assert URI.decode_query(conn.query_string)["invite"] == invitation.token

    {:ok, view, html} = live(conn)
    assert html =~ ~s(data-locale="de")

    BookingTestHelpers.walk_from_schedule_to_booking_form(view, @timezone)
    BookingDriver.submit(view)

    wait_until(fn -> Repo.get_by(MeetingSchema, invitation_id: invitation.id) != nil end)
  end

  @tag :capture_log
  test "a booking-step link with no time picked goes to the times with its invitation", %{
    conn: conn,
    invitation: invitation
  } do
    token = URI.encode_www_form(invitation.token)

    assert {:error, {:redirect, %{to: to}}} =
             live(conn, "/#{@username}/coaching/book?invite=#{token}&timezone=#{@timezone}")

    assert %URI{path: "/#{@username}/coaching", query: query} = URI.parse(to)
    assert URI.decode_query(query)["invite"] == invitation.token

    {:ok, view, _html} = live(conn, to)
    assert has_element?(view, "[data-fact='date']")
  end

  @tag :capture_log
  test "a plain type ignores an invite param", %{conn: conn, invitation: invitation} do
    {:ok, view, _html} =
      live(
        conn,
        "/#{@username}/quick-chat?invite=#{URI.encode_www_form(invitation.token)}&timezone=#{@timezone}"
      )

    BookingTestHelpers.walk_from_schedule_to_booking_form(view, @timezone)
    BookingDriver.submit(view, %{"name" => "Plain Booker", "email" => "plain@example.com"})

    wait_until(fn -> Repo.get_by(MeetingSchema, attendee_email: "plain@example.com") != nil end)

    assert Repo.get_by!(MeetingSchema, attendee_email: "plain@example.com").invitation_id == nil
    assert {:ok, _still_open} = Invitations.resolve(invitation.token)
  end

  @tag :capture_log
  test "the token survives the redirect from a booking-page address", %{
    conn: conn,
    profile: profile,
    type: type,
    invitation: invitation
  } do
    # The page is published by the plain type it lists; the invitation-only
    # one it lists too is still served only at its own address.
    page = insert(:booking_page, profile: profile, slug: "coaching-page")
    plain = Repo.get_by!(MeetingTypeSchema, user_id: profile.user_id, name: "Quick Chat")
    insert(:booking_page_meeting_type, booking_page: page, meeting_type: plain)
    insert(:booking_page_meeting_type, booking_page: page, meeting_type: type)

    token = URI.encode_www_form(invitation.token)

    assert {:error, {:redirect, %{to: to}}} =
             live(conn, "/#{@username}/coaching-page/coaching?invite=#{token}")

    assert %URI{path: "/#{@username}/coaching", query: query} = URI.parse(to)
    assert URI.decode_query(query)["invite"] == invitation.token

    {:ok, view, _html} = live(conn, to <> "&timezone=#{@timezone}")
    BookingTestHelpers.walk_from_schedule_to_booking_form(view, @timezone)
    BookingDriver.submit(view)

    wait_until(fn -> Repo.get_by(MeetingSchema, invitation_id: invitation.id) != nil end)
  end

  @tag :capture_log
  test "the confirmation's address drops the spent invitation token", %{
    conn: conn,
    invitation: invitation
  } do
    view = open_invitation(conn, invitation)
    BookingTestHelpers.walk_from_schedule_to_booking_form(view, @timezone)

    # The steps before the booking keep it, so a reconnect lets the guest in.
    before = BookingTestHelpers.last_patched_url(view)
    assert URI.decode_query(URI.parse(before).query)["invite"] == invitation.token

    BookingDriver.submit(view)
    wait_until(fn -> Repo.get_by(MeetingSchema, invitation_id: invitation.id) != nil end)
    wait_until(fn -> has_element?(view, "[data-intent='restart']") end)

    confirmation = BookingTestHelpers.last_patched_url(view)
    refute Map.has_key?(URI.decode_query(URI.parse(confirmation).query || ""), "invite")
    refute confirmation =~ invitation.token
  end

  test "invite is a reserved username" do
    assert ReservedPaths.reserved?("invite")
  end

  defp invite_path(invitation),
    do:
      "/#{@username}/coaching?invite=#{URI.encode_www_form(invitation.token)}&timezone=#{@timezone}"

  defp open_invitation(conn, invitation) do
    {:ok, view, _html} = live(conn, invite_path(invitation))
    view
  end
end
