defmodule TymeslotWeb.Live.Themes.DetailsCarriedTest do
  @moduledoc """
  The details a visitor typed survive the attendee moment closing and
  opening again within one page view, on the classic journey too: Back from
  the details to the calendar, then Next, brings back the same name, email
  and message, with a fresh submission token.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :bookings
  @moduletag :themes
  @moduletag :integration

  import Mox
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver
  alias TymeslotWeb.BookingDriver.Page
  alias TymeslotWeb.ThemeTestMatrix

  @timezone "America/New_York"

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

  for theme <- Enum.filter(ThemeTestMatrix.all(), &(&1.journey == :classic)) do
    @theme theme

    @tag :capture_log
    test "#{theme.name}: Back then Next keeps the details typed, with a fresh token" do
      %{profile: profile} = seed_booking_account(@theme.id, "carry-#{@theme.slug}", @timezone)

      {:ok, view, _html} =
        live(build_conn(), ~p"/#{profile.username}/quick-chat?timezone=#{@timezone}")

      BookingDriver.book(view, until: :attendee)

      BookingDriver.fill_attendee(view, %{
        name: "Mia Laurent",
        email: "mia@example.com",
        message: "About the spring issue"
      })

      first_token = Page.assigns(view).submission_token

      BookingDriver.back(view)
      refute has_element?(view, "form[data-fact='attendee']")

      # Next on the calendar, its time still picked. Clicked by its intent:
      # `BookingDriver.continue/1` takes the Back just made for a move on.
      view |> element("[data-intent='continue']") |> render_click()

      assert has_element?(
               view,
               "form[data-fact='attendee'] input[name='booking[name]'][value='Mia Laurent']"
             )

      assert has_element?(
               view,
               "form[data-fact='attendee'] input[name='booking[email]'][value='mia@example.com']"
             )

      assert has_element?(
               view,
               "form[data-fact='attendee'] textarea[name='booking[message]']",
               "About the spring issue"
             )

      second_token = Page.assigns(view).submission_token
      assert byte_size(second_token) > 0
      assert second_token != first_token
    end
  end
end
