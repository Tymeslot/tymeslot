defmodule TymeslotWeb.Live.Themes.PaperDetailsRemountTest do
  @moduledoc """
  Paper's details part sets the wide card's booking layout, the heading's
  focus and the scroll to it in a `phx-mounted`. "Change time" only removes
  that class in the browser and leaves the details part mounted, so each
  pick of a time has to mount the element carrying the hook afresh for the
  layout to return. The browser's patch keeps an element whose id is
  unchanged (the heading's), so the hook has to sit on the wrapper whose id
  changes with every pick, not on anything inside it.
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

    # The hook is on the element whose id changed, and on nothing inside it
    # that a patch would keep.
    assert has_element?(view, "##{second}[phx-mounted*='paper-card--booking']")
    assert has_element?(view, "##{second}[phx-mounted*='paper-book-heading']")
    assert has_element?(view, "##{second}[phx-mounted*='tymeslot:reveal']")
    refute has_element?(view, "##{second} [phx-mounted]")
  end

  test "a deep link's details part does not take the focus on load, a picked time's does",
       %{conn: conn, profile: profile} do
    day = Date.utc_today() |> Date.add(3) |> Date.to_iso8601()
    heading = "[data-testid='paper-book'] #paper-book-heading"

    {:ok, view, _html} =
      live(
        conn,
        "/#{profile.username}/quick-chat/book?date=#{day}&time=10:00%20AM&timezone=Etc%2FUTC"
      )

    assert has_element?(view, heading)
    refute has_element?(view, "[data-testid='paper-book'] [phx-mounted]")

    {:ok, view, _html} = live(conn, "/#{profile.username}/quick-chat?timezone=Etc%2FUTC")

    refute has_element?(view, heading)
    BookingDriver.pick_first_slot(view, on: day)

    assert has_element?(view, "#{@head}[phx-mounted*='focus'][phx-mounted*='paper-book-heading']")
    assert has_element?(view, "#{@head} > #paper-book-heading")
  end

  defp head_id(view) do
    [_match, id] = Regex.run(~r/id="(paper-book-head-\d+)"/, render(element(view, @head)))
    id
  end
end
