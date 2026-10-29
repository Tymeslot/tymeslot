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

  test "a page shows its own texts and meeting types", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/einfachiso?timezone=#{@timezone}")

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

  test "a page with nothing listed shows the empty state", %{conn: conn, profile: profile} do
    insert(:booking_page, profile: profile, slug: "empty-page")

    {:ok, _view, html} = live(conn, ~p"/empty-page?timezone=#{@timezone}")

    assert html =~ "No meeting types available"
    refute html =~ "Automation call"
  end

  test "a private type ticked onto a page is on the page, not on the username's page", %{
    conn: conn,
    user: user,
    page: page
  } do
    secret = insert(:meeting_type, user: user, name: "Private strategy", is_private: true)
    :ok = BookingPages.set_meeting_type(page, secret.id, true)

    {:ok, _view, page_html} = live(conn, ~p"/einfachiso?timezone=#{@timezone}")
    {:ok, _view, own_html} = live(conn, ~p"/joern?timezone=#{@timezone}")

    assert page_html =~ "Private strategy"
    refute own_html =~ "Private strategy"
  end

  # Hidden from every start page, and still bookable by its direct link under
  # any of the host's addresses.
  test "a type on no page is still bookable by its direct link", %{conn: conn, user: user} do
    hidden = insert(:meeting_type, user: user, name: "Hidden review", is_private: true)

    for address <- ["einfachiso", "joern"] do
      {:ok, _view, start_html} = live(conn, "/#{address}?timezone=#{@timezone}")
      refute start_html =~ "Hidden review"

      {:ok, view, _html} = live(conn, "/#{address}/hidden-review?timezone=#{@timezone}")
      assert has_element?(view, "button[phx-click='next_month']")
      assert :sys.get_state(view.pid).socket.assigns.meeting_type.id == hidden.id
    end
  end

  test "links inside the flow stay under the page's address", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/einfachiso/iso-audit?timezone=#{@timezone}")

    assert has_element?(view, "button[phx-click='next_month']")

    # The language switcher rebuilds the current step's path the same way the
    # flow's own links do (`PathHandlers`), so it shows where they lead.
    assert {:error, {:redirect, %{to: to}}} =
             render_hook(view, "change_locale", %{"locale" => "de"})

    assert URI.parse(to).path == "/einfachiso/iso-audit"
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

    conn = get(conn, "/einfachiso")

    assert [csp] = Conn.get_resp_header(conn, "content-security-policy")
    assert csp =~ "einfachiso.de"
  end
end
