defmodule TymeslotWeb.BookingPageReturnLinksTest do
  @moduledoc """
  A guest who booked through one of the host's booking pages is sent back
  to that page from the meeting's pages, as the meeting's emails send them:
  after cancelling, after keeping the meeting, and to pick a new time. A
  guest has no session, so "/" would land them on the host's sign-in page.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :bookings
  @moduletag :integration

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.BookingPages
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
    profile = insert(:profile, user: user, username: "ben", timezone: "Etc/UTC")
    listed = insert(:meeting_type, user: user, name: "Beratung")

    %{user: user, profile: profile, listed: listed}
  end

  # The page `theme_id` draws, listing `listed`, and a meeting booked
  # through it.
  defp booked_through_page(%{user: user, profile: profile, listed: listed}, theme_id) do
    page = insert(:booking_page, profile: profile, slug: "espanol", booking_theme: theme_id)
    :ok = BookingPages.set_meeting_type(page, listed.id, true)

    meeting =
      insert(:meeting,
        organizer_user: user,
        organizer_user_id: user.id,
        organizer_name: user.name,
        attendee_timezone: "Etc/UTC",
        status: :confirmed,
        booking_page_id: page.id
      )

    {page, meeting}
  end

  # Each theme words and marks its button its own way; all of them carry the
  # meeting being moved in the path they lead to.
  @choose_new_time "button[phx-click*='reschedule_meeting_uid']"

  defp click_navigation(view, selector, text \\ nil) do
    assert {:error, {_redirect, %{to: to}}} =
             view |> element(selector, text) |> render_click()

    to
  end

  # Quill, Rhythm, and the fixture theme drawn by the shared default pages.
  for theme_id <- ["1", "2", "99"] do
    describe "on theme #{theme_id}" do
      @describetag theme_id: theme_id

      @tag :capture_log
      test "after cancelling, \"Schedule a New Meeting\" leads back to the booking page",
           %{conn: conn, theme_id: theme_id} = context do
        {_page, meeting} = booked_through_page(context, theme_id)

        {:ok, view, _html} = live(conn, ~p"/ben/meeting/#{meeting.uid}/cancel")

        assert {:error, {:redirect, %{to: confirmed_path}}} =
                 view |> element("[data-testid='cancel-meeting']") |> render_click()

        assert Repo.get!(MeetingSchema, meeting.id).status == :cancelled

        {:ok, confirmed, _html} = live(conn, confirmed_path)

        assert click_navigation(confirmed, "button", "Schedule a New Meeting") == "/ben/espanol"
      end

      @tag :capture_log
      test "after keeping the meeting, \"Done\" leads back to the booking page",
           %{conn: conn, theme_id: theme_id} = context do
        {_page, meeting} = booked_through_page(context, theme_id)

        {:ok, view, _html} = live(conn, ~p"/ben/meeting/#{meeting.uid}/cancel")
        view |> element("[data-testid='keep-meeting']") |> render_click()

        assert click_navigation(view, "button", "Done") == "/ben/espanol"
      end

      @tag :capture_log
      test "rescheduling restarts the booking on the booking page",
           %{conn: conn, theme_id: theme_id} = context do
        {_page, meeting} = booked_through_page(context, theme_id)

        {:ok, view, _html} = live(conn, ~p"/ben/meeting/#{meeting.uid}/reschedule")

        assert click_navigation(view, @choose_new_time) ==
                 "/ben/espanol?locale=en&reschedule_meeting_uid=#{meeting.uid}"
      end
    end
  end

  # A page that lists nothing is a draft: no guest can book there, so the
  # buttons lead to the host's own page, as the emails do.
  @tag :capture_log
  test "a draft booking page sends the guest to the host's own page instead",
       %{conn: conn, listed: listed} = context do
    {page, meeting} = booked_through_page(context, "1")
    :ok = BookingPages.set_meeting_type(page, listed.id, false)

    {:ok, view, _html} = live(conn, ~p"/ben/meeting/#{meeting.uid}/reschedule")

    assert click_navigation(view, @choose_new_time) ==
             "/ben?locale=en&reschedule_meeting_uid=#{meeting.uid}"

    {:ok, cancel, _html} = live(conn, ~p"/ben/meeting/#{meeting.uid}/cancel")
    cancel |> element("[data-testid='keep-meeting']") |> render_click()

    assert click_navigation(cancel, "button", "Done") == "/ben"
  end

  test "an unknown meeting sends the guest to the host's booking page", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/ben", flash: %{"error" => _message}}}} =
             live(conn, ~p"/ben/meeting/#{UUID.generate()}/cancel-confirmed")
  end
end
