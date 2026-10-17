defmodule TymeslotWeb.Live.Themes.PaperDetailsRemountTest do
  @moduledoc """
  Paper's details heading carries the wide card's booking layout and the
  focus in its `phx-mounted`. "Change time" only removes that class in the
  browser and leaves the details part mounted, so each pick of a time has to
  mount the heading afresh for the layout to return.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes
  @moduletag :live

  import Mox
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver

  @theme_id "3"
  @head "[data-testid='paper-book'] [id^='paper-book-head-']"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    TestMocks.setup_subscription_mocks()

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start_date, _end_date -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    seed_booking_account(@theme_id, "paper-organiser", "Etc/UTC")
  end

  test "a second pick after Change time mounts the heading afresh", %{
    conn: conn,
    profile: profile
  } do
    day = Date.utc_today() |> Date.add(3) |> Date.to_iso8601()

    {:ok, view, _html} = live(conn, "/#{profile.username}/quick-chat?timezone=Etc%2FUTC")

    BookingDriver.pick_first_slot(view, on: day)
    first = head_id(view)

    # The picker's buttons stay on the page behind "Change time", so the
    # next pick is the same event, even for the same time.
    BookingDriver.pick_first_slot(view, on: day)
    second = head_id(view)

    assert first != second

    assert has_element?(
             view,
             "##{second} #paper-book-heading[phx-mounted*='paper-card--booking']"
           )
  end

  defp head_id(view) do
    [_match, id] = Regex.run(~r/id="(paper-book-head-\d+)"/, render(element(view, @head)))
    id
  end
end
