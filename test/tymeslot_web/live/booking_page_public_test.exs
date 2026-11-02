defmodule TymeslotWeb.BookingPagePublicTest do
  @moduledoc """
  The public side of booking pages: a page's start page, the flow under its
  address, and the profile's own page left as it was.
  """
  use TymeslotWeb.LiveCase, async: false
  @moduletag :scheduling

  import Mox
  import Phoenix.ConnTest
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Plug.Conn
  alias Tymeslot.BookingPages
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias TymeslotWeb.Live.Scheduling.PreviewToken

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

    page =
      insert(:booking_page,
        profile: profile,
        slug: "einfachiso",
        name: "einfachISO",
        booking_text_enabled: true,
        booking_heading: "ISO consulting",
        booking_greeting: "Hello from einfachISO",
        booking_instruction: "Choose a session"
      )

    audit = insert(:meeting_type, user: user, name: "ISO audit", duration_minutes: 30)
    insert(:meeting_type, user: user, name: "Automation call", duration_minutes: 30)
    :ok = BookingPages.set_meeting_type(page, audit.id, true)

    %{user: user, profile: profile, page: page}
  end

  test "a page shows its own texts and meeting types under the username", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/joern/einfachiso?timezone=#{@timezone}")

    assert html =~ "ISO consulting"
    assert html =~ "Choose a session"
    assert html =~ "ISO audit"
    refute html =~ "Automation call"
  end

  test "the username's page is as it was", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/joern?timezone=#{@timezone}")

    refute html =~ "ISO consulting"
    assert html =~ "ISO audit"
    assert html =~ "Automation call"
  end

  # Addresses left the global namespace: a page's slug alone is nobody.
  test "a page's slug is no address of its own", %{conn: conn} do
    assert_error_sent 404, fn -> get(conn, "/einfachiso") end
  end

  test "a page's start page keeps its address on every patch", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/joern/einfachiso?timezone=#{@timezone}")

    # A patch resets the live action to the route's (`/:username/:slug`), which
    # must be read as the page's start page again, not as a meeting type.
    render_patch(view, ~p"/joern/einfachiso?timezone=#{@timezone}&utm_source=x")

    assert render(view) =~ "ISO consulting"
    assert :sys.get_state(view.pid).socket.assigns.live_action == :overview
  end

  describe "a draft page, listing nothing" do
    setup %{profile: profile} do
      %{draft: insert(:booking_page, profile: profile, slug: "draft-page")}
    end

    test "is not there for visitors, at its address or under it", %{conn: conn} do
      # `/<username>/<x>` names a meeting type when `x` is no page.
      assert {:error, {:redirect, %{to: "/joern", flash: %{"error" => "Invalid meeting type"}}}} =
               live(conn, ~p"/joern/draft-page?timezone=#{@timezone}")

      assert_error_sent 404, fn -> get(conn, "/joern/draft-page/iso-audit") end
      assert_error_sent 404, fn -> get(conn, "/joern/draft-page/thank-you") end
    end

    test "shows its owner's preview, with its empty state", %{conn: conn, user: user} do
      token = PreviewToken.sign(user.id)

      {:ok, _view, html} =
        live(conn, ~p"/joern/draft-page?#{[preview: "true", preview_token: token]}")

      assert html =~ "No meeting types available"
      refute html =~ "Automation call"
    end

    test "is no preview for someone else's token", %{conn: conn} do
      token = PreviewToken.sign(insert(:user).id)

      assert {:error, {:redirect, %{to: "/joern" <> _query}}} =
               live(conn, ~p"/joern/draft-page?#{[preview: "true", preview_token: token]}")
    end

    test "is published once it lists a type, and a draft again once it lists none", %{
      draft: draft,
      user: user
    } do
      refute BookingPages.published?(draft)

      type = insert(:meeting_type, user: user, name: "Draft call")
      :ok = BookingPages.set_meeting_type(draft, type.id, true)
      assert BookingPages.published?(draft)

      :ok = BookingPages.set_meeting_type(draft, type.id, false)
      refute BookingPages.published?(draft)
    end
  end

  describe "an address typed with capitals" do
    test "redirects to the lowercase path, query kept", %{conn: conn} do
      for {typed, canonical} <- [
            {"/Joern/EinfachISO", "/joern/einfachiso"},
            {"/joern/EINFACHISO", "/joern/einfachiso"},
            {"/JOERN/einfachiso/iso-audit", "/joern/einfachiso/iso-audit"},
            {"/Joern", "/joern"},
            {"/Joern/automation-call", "/joern/automation-call"}
          ] do
        assert {:error, {:redirect, %{to: to}}} = live(conn, typed <> "?timezone=UTC")
        assert to == canonical <> "?timezone=UTC"
      end
    end

    test "of a username nobody holds is a 404", %{conn: conn} do
      assert_error_sent 404, fn -> get(conn, "/Nobody-Here") end
    end
  end

  describe "a former page address" do
    test "leads to the page's current address, with everything under it", %{
      conn: conn,
      page: page
    } do
      {:ok, _page} = BookingPages.update_details(page, %{"slug" => "iso-pages"})

      for {old, new} <- [
            {"/joern/einfachiso", "/joern/iso-pages"},
            {"/joern/einfachiso/iso-audit", "/joern/iso-pages/iso-audit"},
            {"/joern/einfachiso/iso-audit/book", "/joern/iso-pages/iso-audit/book"},
            {"/joern/einfachiso/thank-you", "/joern/iso-pages/thank-you"},
            {"/joern/EinfachISO", "/joern/iso-pages"}
          ] do
        assert {:error, {:redirect, %{to: to}}} = live(conn, old <> "?timezone=UTC")
        assert to == new <> "?timezone=UTC"
      end

      {:ok, _view, html} = live(conn, ~p"/joern/iso-pages?timezone=#{@timezone}")
      assert html =~ "ISO consulting"
    end

    test "leads to the username's page once the page is deleted", %{conn: conn, page: page} do
      {:ok, _deleted} = BookingPages.delete(page)

      assert {:error, {:redirect, %{to: "/joern"}}} = live(conn, ~p"/joern/einfachiso")

      assert {:error, {:redirect, %{to: "/joern/iso-audit"}}} =
               live(conn, ~p"/joern/einfachiso/iso-audit")
    end

    test "is another host's own to use", %{conn: conn, page: page} do
      {:ok, _page} = BookingPages.update_details(page, %{"slug" => "iso-pages"})
      insert(:profile, username: "someone")

      assert_error_sent 404, fn -> get(conn, "/someone/einfachiso/iso-audit") end
    end
  end

  test "a page address that names no page is a 404", %{conn: conn} do
    assert_error_sent 404, fn -> get(conn, "/joern/no-such-page/iso-audit") end
  end

  test "a private type ticked onto a page is on the page, not on the username's page", %{
    conn: conn,
    user: user,
    page: page
  } do
    secret = insert(:meeting_type, user: user, name: "Private strategy", is_private: true)
    :ok = BookingPages.set_meeting_type(page, secret.id, true)

    {:ok, _view, page_html} = live(conn, ~p"/joern/einfachiso?timezone=#{@timezone}")
    {:ok, _view, own_html} = live(conn, ~p"/joern?timezone=#{@timezone}")

    assert page_html =~ "Private strategy"
    refute own_html =~ "Private strategy"
  end

  # One address per type: hidden from the username's page and listed on a
  # page, its address is under the oldest such page.
  test "a private type listed on pages has its address under the oldest of them", %{
    conn: conn,
    user: user,
    profile: profile,
    page: page
  } do
    newer = insert(:booking_page, profile: profile, slug: "coaching")
    secret = insert(:meeting_type, user: user, name: "Private strategy", is_private: true)
    :ok = BookingPages.set_meeting_type(newer, secret.id, true)
    :ok = BookingPages.set_meeting_type(page, secret.id, true)

    assert BookingPages.meeting_type_path(profile, secret) ==
             "/joern/einfachiso/private-strategy"

    assert {:error, {:redirect, %{to: to}}} =
             live(conn, ~p"/joern/private-strategy?timezone=#{@timezone}")

    assert to == "/joern/einfachiso/private-strategy?timezone=America%2FNew_York"

    assert {:error, {:redirect, %{to: "/joern/einfachiso/private-strategy/book" <> _query}}} =
             live(conn, ~p"/joern/private-strategy/book?date=2030-01-01&time=10:00")

    # Both pages list it, so both serve it.
    for address <- ["/joern/einfachiso", "/joern/coaching"] do
      {:ok, view, _html} = live(conn, "#{address}/private-strategy?timezone=#{@timezone}")
      assert :sys.get_state(view.pid).socket.assigns.meeting_type.id == secret.id
    end
  end

  # Hidden from every start page, and still bookable by its direct link under
  # any of the host's addresses.
  test "a type on no page is still bookable by its direct link", %{
    conn: conn,
    user: user,
    profile: profile
  } do
    hidden = insert(:meeting_type, user: user, name: "Hidden review", is_private: true)
    assert BookingPages.meeting_type_path(profile, hidden) == "/joern/hidden-review"

    for address <- ["joern/einfachiso", "joern"] do
      {:ok, _view, start_html} = live(conn, "/#{address}?timezone=#{@timezone}")
      refute start_html =~ "Hidden review"

      {:ok, view, _html} = live(conn, "/#{address}/hidden-review?timezone=#{@timezone}")
      assert has_element?(view, "button[phx-click='next_month']")
      assert :sys.get_state(view.pid).socket.assigns.meeting_type.id == hidden.id
    end
  end

  # Booked under the page, it would be recorded against a page that does not
  # offer it, and the booking's "book another time" link would lead there.
  test "a type listed on the username's page only goes to its link there", %{
    conn: conn,
    profile: profile,
    user: user
  } do
    automation =
      Repo.get_by!(Tymeslot.MeetingTypes.MeetingTypeSchema,
        user_id: user.id,
        name: "Automation call"
      )

    assert BookingPages.meeting_type_path(profile, automation) == "/joern/automation-call"

    assert {:error, {:redirect, %{to: "/joern/automation-call?timezone=America%2FNew_York"}}} =
             live(conn, ~p"/joern/einfachiso/automation-call?timezone=#{@timezone}")
  end

  test "a type listed on another page only goes to its link there", %{
    conn: conn,
    user: user,
    profile: profile
  } do
    other = insert(:booking_page, profile: profile, slug: "coaching")
    session = insert(:meeting_type, user: user, name: "Coaching session", is_private: true)
    :ok = BookingPages.set_meeting_type(other, session.id, true)

    assert {:error, {:redirect, %{to: "/joern/coaching/coaching-session"}}} =
             live(conn, ~p"/joern/einfachiso/coaching-session")

    {:ok, view, _html} = live(conn, ~p"/joern/coaching/coaching-session?timezone=#{@timezone}")
    assert :sys.get_state(view.pid).socket.assigns.meeting_type.id == session.id
  end

  test "links inside the flow stay under the page's address", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/joern/einfachiso/iso-audit?timezone=#{@timezone}")

    assert has_element?(view, "button[phx-click='next_month']")

    # The language switcher rebuilds the current step's path the same way the
    # flow's own links do (`PathHandlers`), so it shows where they lead.
    assert {:error, {:redirect, %{to: to}}} =
             render_hook(view, "change_locale", %{"locale" => "de"})

    assert URI.parse(to).path == "/joern/einfachiso/iso-audit"
  end

  test "an unknown address is a 404", %{conn: conn} do
    assert_error_sent 404, fn -> get(conn, "/no-such-page-here") end
  end

  test "a page address may be framed on its owner's embed domains", %{
    conn: conn,
    profile: profile
  } do
    profile
    |> Changeset.change(allowed_embed_domains: ["einfachiso.de"])
    |> Repo.update!()

    conn = get(conn, "/joern/einfachiso")

    assert [csp] = Conn.get_resp_header(conn, "content-security-policy")
    assert csp =~ "einfachiso.de"
  end

  test "a page's address renders in its own theme", %{conn: conn, page: page} do
    {:ok, _page} = BookingPages.update_theme(page, "2")

    conn = get(conn, "/joern/einfachiso?timezone=#{@timezone}")

    assert html_response(conn, 200) =~ "rhythm-theme"
  end
end
