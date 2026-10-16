defmodule TymeslotWeb.Live.Themes.ThemeConfirmationActionsTest do
  @moduledoc """
  Every shipped theme's confirmation leads with saving the meeting: Add to
  calendar is the primary action and comes first; starting another booking
  is a quiet link after it.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes
  @moduletag :bookings
  @moduletag :integration

  import Mox
  import Tymeslot.JourneyFixtureHelpers, only: [seed_organiser: 3]

  alias Tymeslot.CalendarMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver
  alias TymeslotWeb.ThemeTestMatrix

  # Each theme's own class for its primary action and for its quiet one.
  @primary %{
    "1" => "action-button--primary",
    "2" => "action-button-primary",
    "3" => "paper-button--primary",
    "4" => "folio-button--primary"
  }
  @quiet %{
    "1" => "confirmation-restart-link",
    "2" => "confirmation-restart-link",
    "3" => "paper-button--quiet",
    "4" => "folio-button--quiet"
  }

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  test "names a class for every shipped theme" do
    for theme <- ThemeTestMatrix.all() do
      assert Map.has_key?(@primary, theme.id) and Map.has_key?(@quiet, theme.id), theme.slug
    end
  end

  for theme <- ThemeTestMatrix.all() do
    @tag :capture_log
    test "theme #{theme.slug}: Add to calendar leads, booking again is a quiet link",
         %{conn: conn} do
      %{profile: profile} =
        seed_organiser(unquote(theme.id), "confirm-actions-#{unquote(theme.slug)}",
          types: [[name: "Quick Chat", duration_minutes: 30]]
        )

      {:ok, view, _html} = live(conn, "/#{profile.username}")
      html = BookingDriver.book(view, attendee: %{name: "Ada Lovelace", email: "ada@example.com"})

      primary = Map.fetch!(@primary, unquote(theme.id))
      quiet = Map.fetch!(@quiet, unquote(theme.id))

      assert has_element?(view, "[data-testid='add-to-calendar'].#{primary}")
      assert has_element?(view, "[data-testid='schedule-another'].#{quiet}")
      refute has_element?(view, "[data-testid='schedule-another'].#{primary}")

      {calendar_at, _length} = :binary.match(html, ~s(data-testid="add-to-calendar"))
      {again_at, _length} = :binary.match(html, ~s(data-testid="schedule-another"))
      assert calendar_at < again_at
    end
  end
end
