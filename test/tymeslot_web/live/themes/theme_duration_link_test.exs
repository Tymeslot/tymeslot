defmodule TymeslotWeb.Live.Themes.ThemeDurationLinkTest do
  @moduledoc """
  A booking page reached through the overview's query form,
  `/<user>?duration=<slug>&date=…` (with or without `&step=`), books the
  meeting type the link names, under that type's rules.

  The failure this guards against: the page carried the slug as the selected
  duration but never resolved the type, so the booking was saved with no
  meeting type at all, and the type's approval, email confirmation, payment,
  limits and questions were skipped while the visitor was told the meeting
  was confirmed. Every theme is walked, by both forms of the link, through
  the moments a visitor would take.
  """

  use TymeslotWeb.LiveCase, async: false

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.JourneyFixtureHelpers, only: [seed_organiser: 3, live_assigns: 1]

  @moduletag :themes
  @moduletag :bookings
  @moduletag :integration

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver
  alias TymeslotWeb.ThemeTestMatrix

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()
    TestMocks.setup_email_mocks()
    TestMocks.setup_subscription_mocks()

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  # Two public types, so no journey settles the type by itself: the gated
  # one the link names, and a plain one beside it.
  defp seed(theme_id, username) do
    seed_organiser(theme_id, username,
      types: [
        [name: "Quick Chat", duration_minutes: 30],
        [
          name: "Verified Call",
          slug: "verified-call",
          duration_minutes: 45,
          requires_approval: true,
          approval_window_hours: 12
        ]
      ]
    )
  end

  defp iso_in(days), do: Date.utc_today() |> Date.add(days) |> Date.to_iso8601()

  defp booked(user, email),
    do: Repo.get_by!(MeetingSchema, organizer_user_id: user.id, attendee_email: email)

  defp book_gated(view, email) do
    # Another day than the link's, as a visitor changing their mind would.
    BookingDriver.book(view,
      meeting_type: "verified-call",
      date: iso_in(5),
      attendee: %{name: "Test Attendee", email: email, message: "Hello!"},
      until: :submitted
    )
  end

  for theme <- ThemeTestMatrix.registered(), step <- [nil, "schedule"] do
    form = if step, do: "with step=#{step}", else: "without a step"

    describe "#{theme.slug}: a ?duration= link #{form}" do
      setup %{conn: conn} do
        seeded = seed(unquote(theme.id), "dl-#{unquote(step || "bare")}-#{unquote(theme.slug)}")
        step_query = if unquote(step), do: "&step=#{unquote(step)}", else: ""

        {:ok, view, _html} =
          live(
            conn,
            "/#{seeded.profile.username}?duration=verified-call&date=#{iso_in(3)}#{step_query}"
          )

        Map.put(seeded, :view, view)
      end

      # The type is what the submit books under, so it is resolved before the
      # visitor does anything: no later moment is relied on to resolve it.
      test "resolves the named type on arrival", %{view: view, meeting_types: [_chat, gated]} do
        assert %{id: id} = live_assigns(view)[:meeting_type]
        assert id == gated.id
      end

      @tag :capture_log
      test "books the named type, held for approval", %{
        view: view,
        user: user,
        meeting_types: [_chat, gated]
      } do
        email = "dl-#{unquote(step || "bare")}-#{unquote(theme.slug)}@example.com"
        book_gated(view, email)

        meeting = booked(user, email)
        assert meeting.meeting_type_id == gated.id
        assert meeting.status == :awaiting_approval
        assert meeting.duration == 45
      end
    end
  end
end
