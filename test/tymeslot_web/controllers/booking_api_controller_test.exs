defmodule TymeslotWeb.BookingApiControllerTest do
  # async: false — the rate-limit test relies on the shared Hammer ETS bucket,
  # which other async tests clear via RateLimiter's test-only reset. Matches the
  # convention of the other rate-limited controller tests (freebusy, session).
  use TymeslotWeb.ConnCase, async: false

  @moduletag :controllers
  @moduletag :bookings

  import Tymeslot.Factory
  import Tymeslot.TestMocks

  alias Tymeslot.BookingApi
  alias Tymeslot.Security.RateLimiter

  setup %{conn: conn} do
    setup_calendar_mocks()

    user = insert(:user)
    profile = insert(:profile, user: user, username: "api-host", full_name: "Ada Host")
    {:ok, profile} = BookingApi.enable(profile)

    %{
      conn: put_req_header(conn, "content-type", "application/json"),
      profile: profile,
      user: user
    }
  end

  defp authed(conn, profile),
    do: put_req_header(conn, "authorization", "Bearer #{profile.booking_api_token}")

  defp body(overrides \\ %{}) do
    start_time =
      DateTime.utc_now()
      |> DateTime.add(2, :day)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    Map.merge(
      %{
        "title" => "Discovery call",
        "attendee_name" => "Robin Vale",
        "attendee_email" => "robin@example.com",
        "start_time" => start_time,
        "duration_minutes" => 30
      },
      overrides
    )
  end

  describe "POST /api/v1/bookings" do
    test "creates the booking and returns 201 with the attendee's links", %{
      conn: conn,
      profile: profile
    } do
      conn = conn |> authed(profile) |> post(~p"/api/v1/bookings", body())

      assert %{"meeting" => meeting} = json_response(conn, 201)
      assert meeting["attendee_email"] == "robin@example.com"
      assert meeting["title"] == "Discovery call"
      assert meeting["status"] == "confirmed"
      assert meeting["duration_minutes"] == 30
      assert meeting["cancel_url"] =~ meeting["uid"]
      assert meeting["reschedule_url"] =~ meeting["uid"]
      assert meeting["view_url"] =~ meeting["uid"]
    end

    test "returns 400 and names every rejected field", %{conn: conn, profile: profile} do
      conn = conn |> authed(profile) |> post(~p"/api/v1/bookings", %{})

      assert %{"error" => error} = json_response(conn, 400)
      assert error["code"] == "invalid_params"
      assert "attendee_email" in Enum.map(error["violations"], & &1["field"])
    end

    test "returns 409 when the organiser is not free", %{conn: conn, profile: profile} do
      start_time = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)

      setup_calendar_mocks(
        events: [
          mock_calendar_event(
            summary: "Already booked",
            start_time: start_time,
            end_time: DateTime.add(start_time, 30, :minute)
          )
        ]
      )

      conn =
        conn
        |> authed(profile)
        |> post(~p"/api/v1/bookings", body(%{"start_time" => DateTime.to_iso8601(start_time)}))

      assert %{"error" => %{"code" => "slot_unavailable"}} = json_response(conn, 409)
    end

    test "returns 422 for a meeting type that does not exist", %{conn: conn, profile: profile} do
      conn =
        conn
        |> authed(profile)
        |> post(~p"/api/v1/bookings", body(%{"meeting_type" => "no-such-type"}))

      assert %{"error" => %{"code" => "meeting_type_not_found"}} = json_response(conn, 422)
    end
  end

  describe "authentication" do
    test "returns 401 without an Authorization header", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/bookings", body())

      assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
    end

    test "returns 401 for an unknown token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer not-a-real-token")
        |> post(~p"/api/v1/bookings", body())

      assert json_response(conn, 401)
    end

    test "returns 401 for a scheme other than Bearer", %{conn: conn, profile: profile} do
      conn =
        conn
        |> put_req_header("authorization", "Token #{profile.booking_api_token}")
        |> post(~p"/api/v1/bookings", body())

      assert json_response(conn, 401)
    end

    test "returns 401 once the organiser disables the endpoint", %{conn: conn, profile: profile} do
      {:ok, _disabled} = BookingApi.disable(profile)

      conn = conn |> authed(profile) |> post(~p"/api/v1/bookings", body())

      assert json_response(conn, 401)
    end

    test "an unknown token is refused without saying why", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer not-a-real-token")
        |> post(~p"/api/v1/bookings", body())

      assert %{"error" => error} = json_response(conn, 401)
      refute Map.has_key?(error, "violations")
      assert error["message"] == "A valid booking API token is required."
    end
  end

  describe "idempotency" do
    test "a repeat under the same key returns 200 and the first meeting", %{
      conn: conn,
      profile: profile
    } do
      first =
        conn
        |> authed(profile)
        |> put_req_header("idempotency-key", "crm-1")
        |> post(~p"/api/v1/bookings", body())

      assert %{"meeting" => %{"uid" => uid}} = json_response(first, 201)

      second =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> authed(profile)
        |> put_req_header("idempotency-key", "crm-1")
        |> post(~p"/api/v1/bookings", body())

      assert %{"meeting" => %{"uid" => ^uid}} = json_response(second, 200)
    end
  end

  describe "rate limiting" do
    test "returns 429 once the per-IP budget is spent", %{conn: conn, profile: profile} do
      # Pin a dedicated remote IP so the bucket is isolated from the other tests
      # in this file, which use the default 127.0.0.1.
      rate_limit_ip = {203, 0, 113, 9}
      bucket_key = "booking_api:ip:203.0.113.9"
      for _i <- 1..120, do: RateLimiter.check_rate(bucket_key, 60_000, 120)

      conn =
        %{conn | remote_ip: rate_limit_ip}
        |> authed(profile)
        |> post(~p"/api/v1/bookings", body())

      assert %{"error" => %{"code" => "rate_limited"}} = json_response(conn, 429)
    end

    test "returns 429 once the organiser's budget is spent", %{
      conn: conn,
      profile: profile,
      user: user
    } do
      bucket_key = "booking_api:user:#{user.id}"
      for _i <- 1..60, do: RateLimiter.check_rate(bucket_key, 60_000, 60)

      conn = conn |> authed(profile) |> post(~p"/api/v1/bookings", body())

      assert %{"error" => %{"code" => "rate_limited"}} = json_response(conn, 429)
    end
  end
end
