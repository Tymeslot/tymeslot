defmodule TymeslotWeb.Live.Themes.ThemeLocaleSwitchBookingTest do
  @moduledoc """
  Booking must survive a language switch.

  This is the seam that let issue #84 ship. Locale switching was covered end to
  end in `multilingual_booking_test.exs`, and booking was covered end to end in
  `theme_booking_flow_test.exs`, but nothing composed the two. A redirect that
  quietly made the page unbookable passed both suites: the visitor picked a
  slot, filled the form, submitted, and nothing happened at all.
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo
  @moduletag :bookings
  @moduletag :i18n

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.ThemeBookingFlowHelpers

  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias TymeslotWeb.Live.Scheduling.PreviewToken

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)

    TestMocks.setup_email_mocks()
    TestMocks.setup_subscription_mocks()

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start_date, _end_date -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  describe "booking survives a language switch" do
    # The gap that let #84 ship. Locale switching was covered end to end and
    # booking was covered end to end, but nothing composed the two, so a
    # redirect that quietly made the page unbookable passed both suites.

    @tag :capture_log
    test "a visitor can still book after using the language switcher", %{conn: conn} do
      timezone = "America/New_York"
      %{user: user, profile: profile} = seed_booking_account("1", "locale-book", timezone)

      {:ok, view, _html} = live(conn, ~p"/#{profile.username}?timezone=#{timezone}")

      conn = switch_language(view, conn, "de")

      # The switcher must not smuggle a preview parameter into the redirect.
      # `theme=` used to arrive here unasked, which is the whole bug.
      refute conn.query_string =~ "theme="
      refute conn.query_string =~ "preview"

      {:ok, view, _html} = live(conn)
      attendee_email = "locale-attendee@example.com"

      confirmation_html =
        complete_booking_flow(view, "quill", "1", %{
          name: "Locale Attendee",
          email: attendee_email,
          message: "Booked after switching language"
        })

      assert confirmation_html =~ attendee_email

      meeting =
        Repo.get_by!(MeetingSchema, organizer_user_id: user.id, attendee_email: attendee_email)

      assert meeting.status == "confirmed"
    end

    @tag :capture_log
    test "a stray ?theme= on a public page does not block the booking", %{conn: conn} do
      # `?theme=` selects which theme renders and nothing more. Anyone can type
      # it, and treating it as a preview claim turned a public booking page
      # unbookable for the price of one query parameter.
      timezone = "America/New_York"
      %{user: user, profile: profile} = seed_booking_account("1", "stray-theme", timezone)

      {:ok, view, _html} =
        live(conn, ~p"/#{profile.username}?theme=1&timezone=#{timezone}")

      attendee_email = "stray-theme-attendee@example.com"

      confirmation_html =
        complete_booking_flow(view, "quill", "1", %{
          name: "Stray Theme Attendee",
          email: attendee_email,
          message: "This must persist"
        })

      assert confirmation_html =~ attendee_email

      assert Repo.get_by(MeetingSchema,
               organizer_user_id: user.id,
               attendee_email: attendee_email
             )
    end

    @tag :capture_log
    test "an owner preview still simulates after a language switch", %{conn: conn} do
      # A locale switch is a full external redirect, so every assign is lost and
      # the preview session survives only if the redirect rebuilds it. If it
      # does not, the owner keeps testing on a page that now books for real and
      # never sees the meetings it creates.
      timezone = "America/New_York"
      %{user: user, profile: profile} = seed_booking_account("1", "preview-locale", timezone)
      token = PreviewToken.sign(user.id)

      {:ok, view, _html} =
        live(
          conn,
          ~p"/#{profile.username}?preview=true&preview_token=#{token}&timezone=#{timezone}"
        )

      conn = switch_language(view, conn, "de")

      assert conn.query_string =~ "preview=true"
      assert conn.query_string =~ "preview_token="

      {:ok, view, _html} = live(conn)

      confirmation_html =
        complete_booking_flow(view, "quill", "1", %{
          name: "Preview Attendee",
          email: "preview-locale@example.com",
          message: "Still simulating"
        })

      assert confirmation_html =~ "preview-locale@example.com"

      # Simulated, exactly as before the switch: no row, no jobs.
      assert Repo.get_by(MeetingSchema, organizer_user_id: user.id) == nil
      assert [] = all_enqueued()
    end
  end

  # Drives the real language switcher and follows the external redirect it
  # issues, returning the conn the visitor lands on. Asserting on that conn's
  # query string is the only way to see what the redirect carried.
  defp switch_language(view, conn, locale) do
    view |> element("button[phx-click='toggle_language_dropdown']") |> render_click()

    {:ok, conn} =
      view
      |> element("button[phx-click='change_locale'][phx-value-locale='#{locale}']")
      |> render_click()
      |> follow_redirect(conn)

    conn
  end
end
