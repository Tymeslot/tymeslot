defmodule TymeslotWeb.Live.Themes.ChosenMeetingTypeShownTest do
  @moduledoc """
  Every theme names the meeting type being booked on each screen after the
  choice, and shows its description where the visitor picks a time, so an
  organiser offering several types of the same length leaves no doubt which
  one is booked (GitHub issue 193). The cancel and reschedule pages name the
  booked type too.

  The organiser offers three 30-minute types; the visitor follows a direct
  link to one of them, the way a shared link or a click from the overview
  lands, so no other type's card is on the page to supply the name.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :bookings
  @moduletag :themes
  @moduletag :integration

  import Mox
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]
  import Tymeslot.Factory

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.MeetingTypes
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver
  alias TymeslotWeb.ThemeTestMatrix

  @timezone "America/New_York"
  @name "Portfolio review"
  @description "Walk me through two pieces of your work and I will give you direct feedback."

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, []}
    end)

    :ok
  end

  for theme <- ThemeTestMatrix.all() do
    @theme theme

    @tag :capture_log
    test "#{theme.name}: the chosen type is named from the calendar to the confirmation" do
      %{user: user, profile: profile} =
        seed_booking_account(@theme.id, "named-#{@theme.slug}", @timezone)

      chosen =
        insert(:meeting_type,
          user: user,
          duration_minutes: 30,
          name: @name,
          description: @description,
          is_active: true
        )

      insert(:meeting_type, user: user, duration_minutes: 30, name: "Follow-up", is_active: true)

      {:ok, view, _html} =
        live(
          build_conn(),
          ~p"/#{profile.username}/#{MeetingTypes.effective_slug(chosen)}?timezone=#{@timezone}"
        )

      html = render(view)
      assert html =~ @name, "the calendar does not name the chosen type"
      assert html =~ @description, "the calendar does not show the chosen type's description"

      BookingDriver.book(view, until: :attendee)
      assert has_element?(view, "form[data-fact='attendee']")
      assert render(view) =~ @name, "the details form does not name the chosen type"

      html = BookingDriver.book(view)
      assert html =~ @name, "the confirmation does not name the booked type"
    end

    for action <- [:cancel, :reschedule, :cancel_confirmed] do
      @action action

      test "#{theme.name}: the #{action} page names the booked type" do
        user = insert(:user)

        profile =
          insert(:profile,
            user: user,
            username: "manage-#{System.unique_integer([:positive])}",
            booking_theme: @theme.id
          )

        meeting =
          insert(:meeting,
            organizer_user: user,
            organizer_user_id: user.id,
            organizer_name: user.name,
            meeting_type: @name,
            status: :confirmed
          )

        path =
          case @action do
            :cancel -> ~p"/#{profile.username}/meeting/#{meeting.uid}/cancel"
            :reschedule -> ~p"/#{profile.username}/meeting/#{meeting.uid}/reschedule"
            :cancel_confirmed -> ~p"/#{profile.username}/meeting/#{meeting.uid}/cancel-confirmed"
          end

        {:ok, view, _html} = live(build_conn(), path)

        assert has_element?(view, "[data-testid='chosen-meeting-type']", @name)
      end
    end
  end
end
