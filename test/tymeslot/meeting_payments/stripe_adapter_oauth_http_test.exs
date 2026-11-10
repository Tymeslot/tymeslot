defmodule Tymeslot.MeetingPayments.StripeAdapterOauthHttpTest do
  @moduledoc """
  The live Stripe Connect OAuth calls, driven through the real HTTP
  transport. Stripe's token endpoint is not idempotent: consuming a code
  twice revokes the connection, so every failure must make exactly one
  request.
  """
  use Tymeslot.HttpTransportCase, async: false

  @moduletag :payments

  alias Tymeslot.MeetingPayments.StripeAdapter.Stripity
  alias Tymeslot.Test.LogCapture

  @platform_key "sk_test_platform_key"

  setup do
    with_config(:stripity_stripe, api_key: @platform_key)
    with_config(:tymeslot, stripe_connect_client_id: "ca_CLIENT")
    :ok
  end

  defp basic_auth(conn), do: Conn.get_req_header(conn, "authorization")

  defp expected_auth, do: ["Basic " <> Base.encode64("#{@platform_key}:")]

  defp json(conn, status, body) do
    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(status, Jason.encode!(body))
  end

  defp counting_stub(responder) do
    counter = :counters.new(1, [:atomics])

    ReqTest.stub(:tymeslot_http, fn conn ->
      :counters.add(counter, 1, 1)
      responder.(conn)
    end)

    counter
  end

  describe "exchange_oauth_code/1" do
    test "a failed exchange makes exactly one request" do
      counter = counting_stub(fn conn -> json(conn, 500, %{"error" => "api_error"}) end)

      assert {:error, :oauth_failed} = Stripity.exchange_oauth_code("ac_CODE")
      assert :counters.get(counter, 1) == 1
    end

    test "a transport error makes exactly one request" do
      counter =
        counting_stub(fn conn -> ReqTest.transport_error(conn, :timeout) end)

      assert {:error, :oauth_failed} = Stripity.exchange_oauth_code("ac_CODE")
      assert :counters.get(counter, 1) == 1
    end

    test "exchange posts the code with the platform key and returns only the account ID" do
      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)

        send(
          test_pid,
          {:request, conn.method, conn.host, conn.request_path, basic_auth(conn),
           URI.decode_query(body)}
        )

        json(conn, 200, %{
          "stripe_user_id" => "acct_X",
          "access_token" => "sk_live_SECRET",
          "refresh_token" => "rt_SECRET",
          "scope" => "read_write"
        })
      end)

      assert Stripity.exchange_oauth_code("ac_CODE") == {:ok, %{stripe_user_id: "acct_X"}}

      assert_received {:request, "POST", "connect.stripe.com", "/oauth/token", auth, form}
      assert auth == expected_auth()
      assert form == %{"grant_type" => "authorization_code", "code" => "ac_CODE"}
    end

    test "a used or expired code is reported as invalid_grant" do
      counter =
        counting_stub(fn conn ->
          json(conn, 400, %{
            "error" => "invalid_grant",
            "error_description" => "Authorization code does not exist: ac_CODE"
          })
        end)

      assert {:error, :invalid_grant} = Stripity.exchange_oauth_code("ac_CODE")
      assert :counters.get(counter, 1) == 1
    end

    test "a 200 without a usable account ID is oauth_failed" do
      bodies = [
        {"no stripe_user_id", fn c -> json(c, 200, %{"access_token" => "sk_live_X"}) end},
        {"non-string stripe_user_id", fn c -> json(c, 200, %{"stripe_user_id" => 42}) end},
        {"non-JSON body", fn c -> Conn.send_resp(c, 200, "<html>ok</html>") end}
      ]

      results =
        for {label, responder} <- bodies do
          ReqTest.stub(:tymeslot_http, responder)
          {label, Stripity.exchange_oauth_code("ac_CODE")}
        end

      assert Enum.reject(results, fn {_label, result} -> result == {:error, :oauth_failed} end) ==
               []

      assert length(results) == 3
    end

    test "a redirect makes exactly one request and is oauth_failed" do
      counter =
        counting_stub(fn conn ->
          conn
          |> Conn.put_resp_header("location", "https://elsewhere.example.com/oauth/token")
          |> Conn.send_resp(307, "")
        end)

      assert {:error, :oauth_failed} = Stripity.exchange_oauth_code("ac_CODE")
      assert :counters.get(counter, 1) == 1
    end

    test "no outcome logs a token, the code or the key" do
      secrets = ["sk_live_LEAKY_TOKEN", "rt_LEAKY_TOKEN", "ac_LEAKY_CODE", @platform_key]

      responders = [
        fn c ->
          json(c, 200, %{
            "stripe_user_id" => "acct_X",
            "access_token" => "sk_live_LEAKY_TOKEN",
            "refresh_token" => "rt_LEAKY_TOKEN"
          })
        end,
        fn c ->
          json(c, 200, %{
            "access_token" => "sk_live_LEAKY_TOKEN",
            "refresh_token" => "rt_LEAKY_TOKEN"
          })
        end,
        fn c ->
          json(c, 400, %{
            "error" => "invalid_grant",
            "error_description" => "Authorization code does not exist: ac_LEAKY_CODE",
            "access_token" => "sk_live_LEAKY_TOKEN"
          })
        end,
        fn c -> ReqTest.transport_error(c, :timeout) end
      ]

      LogCapture.attach(logger_level: :debug)

      for responder <- responders do
        ReqTest.stub(:tymeslot_http, responder)
        Stripity.exchange_oauth_code("ac_LEAKY_CODE")
      end

      events = LogCapture.drain()
      dumped = Enum.map(events, &LogCapture.dump/1)

      assert length(events) >= 4
      assert Enum.filter(dumped, fn text -> Enum.any?(secrets, &(text =~ &1)) end) == []
    end

    test "a refused exchange logs only the operation, status and Stripe's error code" do
      LogCapture.attach(logger_level: :debug)

      ReqTest.stub(:tymeslot_http, fn conn ->
        json(conn, 400, %{"error" => "invalid_grant", "error_description" => "ac_CODE gone"})
      end)

      Stripity.exchange_oauth_code("ac_CODE")

      event = LogCapture.await_log("Stripe OAuth request was not accepted")

      assert LogCapture.user_metadata(event) ==
               %{operation: :exchange_oauth_code, status: 400, error: "invalid_grant"}
    end

    test "a transport failure logs only the operation and the reason atom" do
      LogCapture.attach(logger_level: :debug)
      ReqTest.stub(:tymeslot_http, fn conn -> ReqTest.transport_error(conn, :timeout) end)

      Stripity.exchange_oauth_code("ac_CODE")

      event = LogCapture.await_log("Stripe OAuth request failed")

      assert LogCapture.user_metadata(event) ==
               %{operation: :exchange_oauth_code, reason: :timeout}
    end
  end

  describe "deauthorize_account/1" do
    test "revoking posts the client ID and account" do
      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)

        send(
          test_pid,
          {:request, conn.method, conn.host, conn.request_path, basic_auth(conn),
           URI.decode_query(body)}
        )

        json(conn, 200, %{"stripe_user_id" => "acct_X"})
      end)

      assert :ok = Stripity.deauthorize_account("acct_X")

      assert_received {:request, "POST", "connect.stripe.com", "/oauth/deauthorize", auth, form}
      assert auth == expected_auth()
      assert form == %{"client_id" => "ca_CLIENT", "stripe_user_id" => "acct_X"}
    end

    test "revoking an account that is not connected is not_connected" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        json(conn, 401, %{
          "error" => "invalid_client",
          "error_description" => "This application is not connected to stripe account acct_X"
        })
      end)

      assert {:error, :not_connected} = Stripity.deauthorize_account("acct_X")
    end

    test "invalid_client for any other reason is oauth_failed" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        json(conn, 401, %{
          "error" => "invalid_client",
          "error_description" => "The provided key is a test mode key but this client is live"
        })
      end)

      assert {:error, :oauth_failed} = Stripity.deauthorize_account("acct_X")
    end

    test "a 200 for a different account is oauth_failed" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        json(conn, 200, %{"stripe_user_id" => "acct_OTHER"})
      end)

      assert {:error, :oauth_failed} = Stripity.deauthorize_account("acct_X")

      ReqTest.stub(:tymeslot_http, fn conn -> json(conn, 200, %{}) end)
      assert {:error, :oauth_failed} = Stripity.deauthorize_account("acct_X")
    end

    test "a transport error makes exactly one request" do
      counter = counting_stub(fn conn -> ReqTest.transport_error(conn, :timeout) end)

      assert {:error, :oauth_failed} = Stripity.deauthorize_account("acct_X")
      assert :counters.get(counter, 1) == 1
    end

    test "any other failure is oauth_failed" do
      ReqTest.stub(:tymeslot_http, fn conn -> json(conn, 500, %{"error" => "api_error"}) end)

      assert {:error, :oauth_failed} = Stripity.deauthorize_account("acct_X")
    end
  end
end
