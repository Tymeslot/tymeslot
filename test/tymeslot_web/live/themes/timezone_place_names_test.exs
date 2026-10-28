defmodule TymeslotWeb.Live.Themes.TimezonePlaceNamesTest do
  @moduledoc """
  A guest reads and searches time zones in the booking page's language.

  The labels were English in every locale ("Berlin, Germany" on a German page),
  and search only knew the English names, so a Polish guest typing "Nowy Jork"
  found nothing. The data layer is covered in `Tymeslot.Timezones.DataTest`;
  this pins the page: the picker's trigger and its search answer in German.
  """

  use TymeslotWeb.LiveCase, async: false
  @moduletag :bookings
  @moduletag :i18n

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver

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

  test "a German booking page names and searches places in German", %{conn: conn} do
    %{profile: profile} = seed_booking_account("1", "ortsnamen", "Europe/Berlin")

    {:ok, view, _html} =
      live(conn, ~p"/#{profile.username}?timezone=Europe/Berlin&locale=de")

    BookingDriver.choose_meeting_type(view, "quick-chat")
    BookingDriver.continue(view)

    assert view |> element(".tz-picker__trigger") |> render() =~ "Berlin, Deutschland"

    view |> element(".tz-picker__trigger") |> render_click()
    view |> element(".tz-picker__search") |> render_keyup(%{"value" => "Wien"})

    assert view
           |> element(".tz-picker__option[phx-value-timezone='Europe/Vienna']")
           |> render() =~ "Wien, Österreich"
  end
end
