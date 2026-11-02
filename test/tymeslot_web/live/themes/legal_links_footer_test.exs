defmodule TymeslotWeb.Live.Themes.LegalLinksFooterTest do
  @moduledoc """
  The organiser's legal notice and privacy policy links at the foot of every
  public page a guest reaches, on every shipped theme: the booking flow from
  the overview to the confirmation, the meeting pages, the poll and both
  payment return pages (which hide the theme extensions but keep the
  footer), and the embedded booking page. With no links set nothing renders.

  The instance defaults are application-wide configuration and stay unset
  here (nil in every test config); `LegalLinksDefaultsTest` covers them.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :themes
  @moduletag :profiles

  import Mox
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]
  import Tymeslot.Factory

  alias Tymeslot.Profiles
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver
  alias TymeslotWeb.ThemeTestMatrix

  @notice "https://example.com/imprint"
  @privacy "https://example.com/privacy"
  @footer "footer[data-testid='legal-links']"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    TestMocks.setup_email_mocks()
    TestMocks.setup_subscription_mocks()

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  defp seed(
         theme_id,
         username,
         links \\ %{"legal_notice_url" => @notice, "privacy_policy_url" => @privacy}
       ) do
    %{user: user, profile: profile} = seed_booking_account(theme_id, username, "Etc/UTC")
    {:ok, profile} = Profiles.update_legal_links(profile, links)
    %{user: user, profile: profile}
  end

  defp assert_footer(view) do
    assert has_element?(view, "#{@footer} a[href='#{@notice}']", "Legal notice")
    assert has_element?(view, "#{@footer} a[href='#{@privacy}']", "Privacy policy")
  end

  defp meeting(user) do
    start = DateTime.add(DateTime.utc_now(:second), 3, :day)

    insert(:meeting,
      organizer_user_id: user.id,
      organizer_name: "Legal Host",
      start_time: start,
      end_time: DateTime.add(start, 30, :minute),
      duration: 30,
      attendee_timezone: "Etc/UTC",
      status: :confirmed
    )
  end

  for theme <- ThemeTestMatrix.all() do
    describe "#{theme.slug}" do
      setup do
        seed(unquote(theme.id), "legal-#{unquote(theme.slug)}")
      end

      test "#{theme.slug} overview shows the footer", %{conn: conn, profile: profile} do
        {:ok, view, _html} = live(conn, ~p"/#{profile.username}")
        assert_footer(view)
      end

      test "#{theme.slug} schedule shows the footer", %{conn: conn, profile: profile} do
        {:ok, view, _html} = live(conn, ~p"/#{profile.username}")
        [slug | _others] = BookingDriver.meeting_types(view)
        BookingDriver.choose_meeting_type(view, slug)

        assert has_element?(view, "[data-fact='date'], [data-fact='slot']")
        assert_footer(view)
      end

      @tag :capture_log
      test "#{theme.slug} booking shows the footer", %{conn: conn, profile: profile} do
        {:ok, view, _html} = live(conn, ~p"/#{profile.username}")
        BookingDriver.book(view, until: :attendee)

        assert has_element?(view, "form[data-fact='attendee']")
        assert_footer(view)
      end

      @tag :capture_log
      test "#{theme.slug} thank-you shows the footer", %{conn: conn, profile: profile} do
        {:ok, view, _html} = live(conn, ~p"/#{profile.username}")
        BookingDriver.book(view)

        assert has_element?(view, "[data-testid='confirmation-heading']")
        assert_footer(view)
      end

      test "#{theme.slug} cancel shows the footer", %{conn: conn, user: user, profile: profile} do
        meeting = meeting(user)
        {:ok, view, _html} = live(conn, ~p"/#{profile.username}/meeting/#{meeting.uid}/cancel")

        assert has_element?(view, "[data-testid='#{unquote(theme.slug)}-cancel']")
        assert has_element?(view, "[data-testid='cancel-meeting']")
        assert_footer(view)
      end

      test "#{theme.slug} cancel-confirmed shows the footer",
           %{conn: conn, user: user, profile: profile} do
        meeting = meeting(user)

        {:ok, view, _html} =
          live(conn, ~p"/#{profile.username}/meeting/#{meeting.uid}/cancel-confirmed")

        assert has_element?(view, "[data-testid='#{unquote(theme.slug)}-cancel-confirmed']")
        assert_footer(view)
      end

      test "#{theme.slug} reschedule shows the footer",
           %{conn: conn, user: user, profile: profile} do
        meeting = meeting(user)

        {:ok, view, _html} =
          live(conn, ~p"/#{profile.username}/meeting/#{meeting.uid}/reschedule")

        assert has_element?(view, "[data-testid='#{unquote(theme.slug)}-reschedule']")
        assert_footer(view)
      end

      test "#{theme.slug} poll voting shows the footer",
           %{conn: conn, user: user, profile: profile} do
        poll = insert(:poll, user: user)
        insert(:poll_time_slot, poll: poll)

        {:ok, view, _html} = live(conn, "/#{profile.username}/poll/#{poll.token}")

        assert has_element?(view, "[data-testid='poll-voting']")
        assert_footer(view)
      end

      test "#{theme.slug} payment processing shows the footer",
           %{conn: conn, user: user} do
        meeting = insert(:meeting, organizer_user_id: user.id, status: :awaiting_payment)

        insert(:booking_payment,
          meeting: meeting,
          host_user_id: user.id,
          status: :pending,
          stripe_checkout_session_id: "cs_LEGAL"
        )

        {:ok, view, _html} =
          live(
            conn,
            "/themes/#{unquote(theme.slug)}/payment-processing/#{meeting.id}?session_id=cs_LEGAL"
          )

        assert has_element?(view, "[data-testid='#{unquote(theme.slug)}-payment-processing']")
        assert_footer(view)
      end

      test "#{theme.slug} payment cancelled shows the footer", %{conn: conn, user: user} do
        meeting = insert(:meeting, organizer_user_id: user.id, status: :awaiting_payment)

        {:ok, view, _html} =
          live(conn, "/themes/#{unquote(theme.slug)}/payment-cancelled/#{meeting.id}")

        assert has_element?(view, "[data-testid='#{unquote(theme.slug)}-payment-cancelled']")
        assert_footer(view)
      end

      test "#{theme.slug} shows no footer when nothing is set", %{conn: conn} do
        %{profile: profile} = seed(unquote(theme.id), "nolinks-#{unquote(theme.slug)}", %{})

        {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

        assert has_element?(view, "[data-booker-root]")
        refute has_element?(view, @footer)
      end
    end
  end

  test "embedded booking page keeps the footer", %{conn: conn} do
    %{profile: profile} = seed("1", "legal-embed")
    {:ok, profile} = Profiles.update_allowed_embed_domains(profile, ["embedder.org"])

    conn = put_req_header(conn, "referer", "https://embedder.org/page")
    {:ok, view, _html} = live(conn, "/#{profile.username}?embed=1")

    assert :sys.get_state(view.pid).socket.assigns[:embedded] == true
    assert_footer(view)
  end
end
