defmodule TymeslotWeb.GuestRsvpControllerTest do
  # Uses the global ETS rate limiter; must not run concurrently.
  use TymeslotWeb.ConnCase, async: false
  @moduletag :meetings

  alias Tymeslot.Factory
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Security.RateLimiter

  setup do
    RateLimiter.clear_all()
    meeting = Factory.insert(:meeting)
    {:ok, [guest]} = Guests.create_for_meeting(meeting.id, ["guest@example.com"])
    %{guest: guest}
  end

  describe "GET /guest/:token/:response — confirmation landing page (no mutation)" do
    test "accept link shows the pre-confirmation page without recording the RSVP", %{
      conn: conn,
      guest: guest
    } do
      conn = get(conn, ~p"/guest/#{guest.rsvp_token}/accept")

      assert html_response(conn, 200) =~ "about to accept"
      assert {:ok, reloaded} = GuestQueries.get_by_token(guest.rsvp_token)
      assert reloaded.status == "pending"
    end

    test "decline link shows the pre-confirmation page without recording the RSVP", %{
      conn: conn,
      guest: guest
    } do
      conn = get(conn, ~p"/guest/#{guest.rsvp_token}/decline")

      assert html_response(conn, 200) =~ "about to decline"
      assert {:ok, reloaded} = GuestQueries.get_by_token(guest.rsvp_token)
      assert reloaded.status == "pending"
    end

    test "an unknown token shows the invalid page", %{conn: conn} do
      conn = get(conn, ~p"/guest/nope-not-a-token/accept")

      assert html_response(conn, 404) =~ "no longer valid"
    end

    test "an invalid response value shows the invalid page", %{conn: conn, guest: guest} do
      conn = get(conn, ~p"/guest/#{guest.rsvp_token}/maybe")

      assert html_response(conn, 404) =~ "no longer valid"
      assert {:ok, reloaded} = GuestQueries.get_by_token(guest.rsvp_token)
      assert reloaded.status == "pending"
    end
  end

  describe "POST /guest/:token/:response — records the RSVP" do
    test "accepting records the RSVP and shows the success page", %{conn: conn, guest: guest} do
      conn = post(conn, ~p"/guest/#{guest.rsvp_token}/accept")

      assert html_response(conn, 200) =~ "going!"
      assert {:ok, reloaded} = GuestQueries.get_by_token(guest.rsvp_token)
      assert reloaded.status == "accepted"
      assert %DateTime{} = reloaded.responded_at
    end

    test "declining records the RSVP and shows the success page", %{conn: conn, guest: guest} do
      conn = post(conn, ~p"/guest/#{guest.rsvp_token}/decline")

      assert html_response(conn, 200) =~ "declined"
      assert {:ok, reloaded} = GuestQueries.get_by_token(guest.rsvp_token)
      assert reloaded.status == "declined"
    end

    test "an unknown token shows the invalid page", %{conn: conn} do
      conn = post(conn, ~p"/guest/nope-not-a-token/accept")

      assert html_response(conn, 404) =~ "no longer valid"
    end

    test "an invalid response value shows the invalid page", %{conn: conn, guest: guest} do
      conn = post(conn, ~p"/guest/#{guest.rsvp_token}/maybe")

      assert html_response(conn, 404) =~ "no longer valid"
      assert {:ok, reloaded} = GuestQueries.get_by_token(guest.rsvp_token)
      assert reloaded.status == "pending"
    end
  end
end
