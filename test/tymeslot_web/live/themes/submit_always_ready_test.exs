defmodule TymeslotWeb.Live.Themes.SubmitAlwaysReadyTest do
  @moduledoc """
  The booking form's submit button is never held back by what the server
  last saw of the form. Name and email reach the server only on blur, so a
  button gated on that state stays disabled after the visitor has typed
  everything: Enter in the email field does nothing, and the first click is
  lost. The button is pressable from the start on every theme, and an
  incomplete form is answered on submit with the fields' errors.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :bookings
  @moduletag :themes
  @moduletag :integration

  import Mox
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver
  alias TymeslotWeb.ThemeTestMatrix

  @timezone "America/New_York"
  @submit "[data-testid='submit-booking']"

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
    test "#{theme.name}: the submit button is enabled on an untouched form" do
      %{profile: profile} = seed_booking_account(@theme.id, "ready-#{@theme.slug}", @timezone)
      view = open(profile)

      BookingDriver.book(view, until: :attendee)

      assert has_element?(view, @submit)
      refute has_element?(view, "#{@submit}[disabled]")
    end

    @tag :capture_log
    test "#{theme.name}: submitting an empty form shows the field errors and books nothing" do
      %{user: user, profile: profile} =
        seed_booking_account(@theme.id, "empty-#{@theme.slug}", @timezone)

      view = open(profile)
      BookingDriver.book(view, until: :attendee)

      html = BookingDriver.submit(view)

      assert html =~ "Name is required"
      assert html =~ "Email is required"
      refute has_element?(view, "#{@submit}[disabled]")
      assert Repo.get_by(MeetingSchema, organizer_user_id: user.id) == nil
    end
  end

  defp open(profile) do
    {:ok, view, _html} =
      live(build_conn(), ~p"/#{profile.username}/quick-chat?timezone=#{@timezone}")

    view
  end
end
