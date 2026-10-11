defmodule TymeslotWeb.Live.Scheduling.BookingPageViewTest do
  @moduledoc """
  A visit to a booking page's address is logged as a page view for the owner,
  exactly like a visit to `/<username>`.
  """
  use TymeslotWeb.LiveCase, async: false

  import Tymeslot.Factory

  alias Tymeslot.Analytics.EventSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter

  @moduletag :scheduling
  @moduletag :live

  setup do
    RateLimiter.clear_all()
    Repo.delete_all(EventSchema)
    :ok
  end

  test "visiting the page address records a page view for the owner", %{conn: conn} do
    user = insert(:user)

    profile =
      insert(:profile, user: user, username: "owner-#{System.unique_integer([:positive])}")

    insert(:booking_page, profile: profile, slug: "einfachiso")

    {:ok, _view, _html} =
      conn
      |> put_req_header("user-agent", "Mozilla/5.0 (Macintosh) Chrome/126.0.0.0")
      |> live(~p"/einfachiso")

    assert [event] = Repo.all(EventSchema)
    assert event.event_type == "booking_page_view"
    assert event.user_id == user.id
    assert event.path == "/einfachiso"
  end
end
