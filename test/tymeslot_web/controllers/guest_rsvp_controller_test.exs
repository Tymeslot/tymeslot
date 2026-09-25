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

  defp guest_for(meeting_attrs) do
    meeting = Factory.insert(:meeting, meeting_attrs)
    {:ok, [guest]} = Guests.create_for_meeting(meeting.id, ["late@example.com"])
    guest
  end

  defp past_meeting_attrs do
    start_time = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)
    [start_time: start_time, end_time: DateTime.add(start_time, 60, :minute)]
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

      assert html_response(conn, 404) =~ "link is not valid"
    end

    test "an invalid response value shows the invalid page", %{conn: conn, guest: guest} do
      conn = get(conn, ~p"/guest/#{guest.rsvp_token}/maybe")

      assert html_response(conn, 404) =~ "link is not valid"
      assert {:ok, reloaded} = GuestQueries.get_by_token(guest.rsvp_token)
      assert reloaded.status == "pending"
    end
  end

  describe "GET /guest/:token/:response — meeting no longer taking responses" do
    test "a cancelled meeting shows the closed page", %{conn: conn} do
      guest = guest_for(status: "cancelled")

      conn = get(conn, ~p"/guest/#{guest.rsvp_token}/accept")

      assert html_response(conn, 410) =~ "no longer taking responses"
    end

    test "a meeting that has already started shows the closed page", %{conn: conn} do
      guest = guest_for(past_meeting_attrs())

      conn = get(conn, ~p"/guest/#{guest.rsvp_token}/accept")

      assert html_response(conn, 410) =~ "no longer taking responses"
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

      assert html_response(conn, 404) =~ "link is not valid"
    end

    test "an invalid response value shows the invalid page", %{conn: conn, guest: guest} do
      conn = post(conn, ~p"/guest/#{guest.rsvp_token}/maybe")

      assert html_response(conn, 404) =~ "link is not valid"
      assert {:ok, reloaded} = GuestQueries.get_by_token(guest.rsvp_token)
      assert reloaded.status == "pending"
    end

    test "the success page links to the opposite response", %{conn: conn, guest: guest} do
      conn = post(conn, ~p"/guest/#{guest.rsvp_token}/accept")

      assert html_response(conn, 200) =~ ~s(href="/guest/#{guest.rsvp_token}/decline")
    end
  end

  describe "POST /guest/:token/:response — meeting no longer taking responses" do
    test "a cancelled meeting is not answered", %{conn: conn} do
      guest = guest_for(status: "cancelled")

      conn = post(conn, ~p"/guest/#{guest.rsvp_token}/accept")

      assert html_response(conn, 410) =~ "no longer taking responses"
      assert {:ok, %{status: "pending"}} = GuestQueries.get_by_token(guest.rsvp_token)
    end

    test "a meeting that has already started is not answered", %{conn: conn} do
      guest = guest_for(past_meeting_attrs())

      conn = post(conn, ~p"/guest/#{guest.rsvp_token}/decline")

      assert html_response(conn, 410) =~ "no longer taking responses"
      assert {:ok, %{status: "pending"}} = GuestQueries.get_by_token(guest.rsvp_token)
    end
  end

  describe "rate limiting" do
    test "the landing page and the response share one per-client limit", %{
      conn: conn,
      guest: guest
    } do
      for _attempt <- 1..60 do
        assert build_conn() |> get(~p"/guest/#{guest.rsvp_token}/accept") |> html_response(200)
      end

      conn = post(conn, ~p"/guest/#{guest.rsvp_token}/accept")

      assert html_response(conn, 429) =~ "Too many attempts"
      assert {:ok, %{status: "pending"}} = GuestQueries.get_by_token(guest.rsvp_token)
    end
  end
end
