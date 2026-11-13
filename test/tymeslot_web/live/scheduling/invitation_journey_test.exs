defmodule TymeslotWeb.Live.Scheduling.InvitationJourneyTest do
  @moduledoc """
  An invitation link, end to end, as the host and the person invited use it:
  the host makes a type invitation-only and creates a link in the dashboard,
  the visitor opens it and books, cancels and reschedules through the
  meeting's own manage pages, and the host watches the link's status follow
  along in the invitations panel, revoking or reopening it.

  The host and the visitor each have their own conn; the visitor is never
  signed in. Emails and Oban jobs stay in the test's normal mode.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :bookings

  import Mox
  import Tymeslot.AuthTestHelpers, only: [log_in_user: 2]
  import Tymeslot.Factory
  import Tymeslot.Test.ClockHelpers, only: [with_frozen_clock: 2]

  alias Ecto.Changeset
  alias Phoenix.Flash
  alias Tymeslot.BookingTestHelpers
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Invitations.InvitationSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver
  alias TymeslotWeb.Live.Scheduling.InvitationMessages

  @timezone "Etc/UTC"
  @username "schoolhost"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    recaptcha = Application.get_env(:tymeslot, :recaptcha, [])
    Application.put_env(:tymeslot, :recaptcha, Keyword.put(recaptcha, :booking_enabled, false))
    on_exit(fn -> Application.put_env(:tymeslot, :recaptcha, recaptcha) end)

    %{user: user, profile: profile} =
      BookingTestHelpers.seed_booking_account("1", @username, @timezone)

    user =
      user
      |> Changeset.change(onboarding_completed_at: DateTime.utc_now(:second))
      |> Repo.update!()

    type =
      insert(:meeting_type,
        user: user,
        name: "Parent meeting",
        slug: "parent-meeting",
        duration_minutes: 30,
        is_active: true
      )

    host = build_conn() |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)

    %{host: host, user: user, profile: profile, type: type}
  end

  @tag :capture_log
  test "a reusable link books, frees on cancel, books again, moves, and survives a revoke",
       ctx do
    # 1. The host makes the type invitation-only and invites Ada.
    editor = open_editor(ctx.host, ctx.type)
    editor |> element("#meeting-type-invitation-only-toggle-#{ctx.type.id}") |> render_click()
    # "Reusable after cancellation" is left on.
    assert has_element?(
             editor,
             "#invitations-#{ctx.type.id}-release-on-cancel[role='switch'][aria-checked='true']"
           )

    url = create_invitation(editor, ctx.type, %{name: "Ada Parent", email: "ada@example.com"})
    [invitation_row] = invitation_rows(editor)

    assert has_element?(editor, "#{invitation_row}[data-status='available']", "Ada Parent")
    assert [%{release_on_cancel: true}] = Repo.all(InvitationSchema)

    # 2. The link leads to the type, and the form is prefilled with Ada's details.
    view = open_link(url)
    BookingDriver.book(view, until: :attendee)

    assert has_element?(view, "input[name='booking[name]'][value='Ada Parent']")
    assert has_element?(view, "input[name='booking[email]'][value='ada@example.com']")

    meeting = submit_and_confirm(view)
    assert meeting.attendee_name == "Ada Parent"

    # 3. The host sees the link used, booked for that time (on the 12-hour
    # clock an English dashboard defaults to).
    editor = open_editor(ctx.host, ctx.type)
    assert has_element?(editor, "#{invitation_row}[data-status='used']")

    assert has_element?(
             editor,
             "#{invitation_row} [data-testid='invitation-booked-at']",
             Calendar.strftime(meeting.start_time, "%-I:%M %p")
           )

    # 4. The link now refuses.
    assert refusal(url) == InvitationMessages.message(:used)

    # 5. Ada cancels through the meeting's cancel page; the link is free again.
    cancel(meeting)

    editor = open_editor(ctx.host, ctx.type)
    assert has_element?(editor, "#{invitation_row}[data-status='available']")

    # 6. The same link books again, and the booking moves through its
    # reschedule page.
    view = open_link(url)
    BookingDriver.book(view, until: :attendee)
    rebooked = submit_and_confirm(view)
    refute rebooked.id == meeting.id

    moved = reschedule(rebooked)
    assert moved.id == rebooked.id

    assert [%{id: live_id}] = live_meetings(ctx.user)
    assert live_id == rebooked.id

    editor = open_editor(ctx.host, ctx.type)
    assert has_element?(editor, "#{invitation_row}[data-status='used']")

    # 7. The host revokes: the booking stays, and used outranks revoked. The
    # panel offers Revoke on an available link only, so a used one is revoked
    # by the panel's own event, as a page loaded before the booking would.
    refute has_element?(editor, "#{invitation_row} [phx-click='ask_revoke']")
    [_hash, invitation_id] = Regex.run(~r/^#invitation-(\d+)$/, invitation_row)

    editor
    |> with_target("#invitations-#{ctx.type.id}")
    |> render_click("revoke", %{"id" => invitation_id})

    assert Repo.get_by!(InvitationSchema, id: invitation_id).revoked_at
    assert Repo.get!(MeetingSchema, rebooked.id).status == :confirmed
    assert has_element?(editor, "#{invitation_row}[data-status='used']")
  end

  @tag :capture_log
  test "a single-use link stays used after a cancel until the host reopens it", ctx do
    editor = open_editor(ctx.host, ctx.type)
    editor |> element("#meeting-type-invitation-only-toggle-#{ctx.type.id}") |> render_click()
    editor |> element("#invitations-#{ctx.type.id}-release-on-cancel") |> render_click()
    url = create_invitation(editor, ctx.type, %{name: "Ada Parent", email: "ada@example.com"})
    [invitation_row] = invitation_rows(editor)

    view = open_link(url)
    BookingDriver.book(view, until: :attendee)
    meeting = submit_and_confirm(view)

    cancel(meeting)

    editor = open_editor(ctx.host, ctx.type)
    assert has_element?(editor, "#{invitation_row}[data-status='used']")

    assert has_element?(
             editor,
             "#{invitation_row} [data-testid='invitation-cancelled']",
             "Appointment cancelled"
           )

    assert refusal(url) == InvitationMessages.message(:used)

    # Later, the host reopens it. A reopen frees the link from meetings
    # booked before it, compared to the second, so it happens a minute on.
    with_frozen_clock(DateTime.add(DateTime.utc_now(), 60, :second), fn ->
      editor |> element("#{invitation_row} [phx-click='reopen']") |> render_click()
    end)

    assert has_element?(editor, "#{invitation_row}[data-status='available']")

    view = open_link(url)
    BookingDriver.book(view, until: :attendee)
    rebooked = submit_and_confirm(view)

    assert rebooked.status == :confirmed
    assert [%{id: live_id}] = live_meetings(ctx.user)
    assert live_id == rebooked.id

    editor = open_editor(ctx.host, ctx.type)
    assert has_element?(editor, "#{invitation_row}[data-status='used']")
  end

  # -- the host ---------------------------------------------------------------

  defp open_editor(host, type) do
    {:ok, view, _html} = live(host, ~p"/dashboard/meeting-settings")
    view |> element("[phx-click='edit_type'][phx-value-id='#{type.id}']") |> render_click()
    view
  end

  # Creates a link from the panel's form and returns the URL its copy button
  # carries.
  defp create_invitation(editor, type, attrs) do
    editor |> form("#invitations-#{type.id}-form", invitation: attrs) |> render_submit()

    [url] =
      editor
      |> render()
      |> Floki.parse_document!()
      |> Floki.find("[id^='copy-invitation-']")
      |> Floki.attribute("data-copy-text")

    assert url =~ ~r{/invite/[^/]+$}
    url
  end

  defp invitation_rows(editor) do
    editor
    |> render()
    |> Floki.parse_document!()
    |> Floki.find("li[id^='invitation-']")
    |> Floki.attribute("id")
    |> Enum.map(&"##{&1}")
  end

  # -- the visitor ------------------------------------------------------------

  defp link_path(url), do: URI.parse(url).path

  # Opens the link as a visitor does: `/invite/<token>` redirects to the type
  # carrying the token.
  defp open_link(url) do
    conn = get(build_conn(), link_path(url))
    to = redirected_to(conn)

    assert %URI{path: "/#{@username}/parent-meeting", query: query} = URI.parse(to)
    assert Map.has_key?(URI.decode_query(query), "invite")

    {:ok, view, _html} = live(build_conn(), to <> "&timezone=#{@timezone}")
    view
  end

  # The message a refused link redirects to the host's page with.
  defp refusal(url) do
    conn = get(build_conn(), link_path(url))
    assert redirected_to(conn) == "/#{@username}"
    Flash.get(conn.assigns.flash, :error)
  end

  defp submit_and_confirm(view) do
    before = MapSet.new(Repo.all(MeetingSchema), & &1.id)
    BookingDriver.submit(view)
    wait_until(fn -> has_element?(view, "[data-intent='restart']") end)

    [meeting] = Enum.reject(Repo.all(MeetingSchema), &MapSet.member?(before, &1.id))
    assert meeting.invitation_id
    meeting
  end

  defp cancel(meeting) do
    {:ok, view, _html} = live(build_conn(), "/#{@username}/meeting/#{meeting.uid}/cancel")

    assert {:error, {:redirect, %{to: to}}} =
             view |> element("[data-testid='cancel-meeting']") |> render_click()

    assert to == "/#{@username}/meeting/#{meeting.uid}/cancel-confirmed"
    assert Repo.get!(MeetingSchema, meeting.id).status == :cancelled
  end

  # Moves `meeting` a day later through its reschedule page, which leads into
  # the booking flow without any invitation token.
  defp reschedule(meeting) do
    {:ok, page, _html} = live(build_conn(), "/#{@username}/meeting/#{meeting.uid}/reschedule")

    to = navigate_target(page, "[data-testid='reschedule-continue']")
    refute to =~ "invite="

    {:ok, view, _html} = live(build_conn(), to <> "&timezone=#{@timezone}")
    BookingDriver.choose_meeting_type(view, "parent-meeting")
    BookingDriver.continue(view)

    later = Date.to_iso8601(Date.add(DateTime.to_date(meeting.start_time), 1))
    BookingDriver.pick_first_slot(view, on: later)
    BookingDriver.continue(view)
    BookingDriver.submit(view)

    wait_until(fn -> Repo.get!(MeetingSchema, meeting.id).start_time != meeting.start_time end)
    Repo.get!(MeetingSchema, meeting.id)
  end

  # The address a `JS.navigate` control sends the browser to; LiveViewTest
  # runs no client commands, so the test follows it itself.
  defp navigate_target(view, selector) do
    [command] =
      view
      |> element(selector)
      |> render()
      |> Floki.parse_fragment!()
      |> Floki.attribute("phx-click")

    [["navigate", %{"href" => href}]] = Jason.decode!(command)
    href
  end

  defp live_meetings(user) do
    occupying = MeetingState.occupying()

    MeetingSchema
    |> Repo.all()
    |> Enum.filter(&(&1.organizer_user_id == user.id and &1.status in occupying))
  end
end
