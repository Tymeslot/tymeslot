defmodule Tymeslot.Integrations.Stripe.RequestTest do
  use ExUnit.Case, async: true

  alias Tymeslot.Integrations.Stripe.Request

  @moduletag :payments
  @moduletag :unit

  @version "2025-11-17.clover"

  defp user_agent, do: "Tymeslot/" <> to_string(Application.spec(:tymeslot, :vsn))

  describe "headers/2" do
    test "a POST carries the form content type and its idempotency key" do
      request =
        Request.new(:create_refund, :post, ["refunds"], %{amount: 500},
          api_key: "sk_test_x",
          idempotency_key: "k1"
        )

      assert Request.headers(request, @version) == [
               {"authorization", "Bearer sk_test_x"},
               {"stripe-version", @version},
               {"accept", "application/json"},
               {"user-agent", user_agent()},
               {"content-type", "application/x-www-form-urlencoded"},
               {"idempotency-key", "k1"}
             ]
    end

    test "a POST on a connected account names the account last" do
      request =
        Request.new(:create_refund, :post, ["refunds"], %{},
          api_key: "sk_test_x",
          idempotency_key: "k1",
          connect_account: "acct_1"
        )

      assert Request.headers(request, @version) == [
               {"authorization", "Bearer sk_test_x"},
               {"stripe-version", @version},
               {"accept", "application/json"},
               {"user-agent", user_agent()},
               {"content-type", "application/x-www-form-urlencoded"},
               {"idempotency-key", "k1"},
               {"stripe-account", "acct_1"}
             ]
    end

    test "a GET has no content type and no idempotency key" do
      request =
        Request.new(:retrieve_charge, :get, ["charges", "ch_1"], %{},
          api_key: "sk_test_x",
          idempotency_key: "ignored"
        )

      assert Request.headers(request, @version) == [
               {"authorization", "Bearer sk_test_x"},
               {"stripe-version", @version},
               {"accept", "application/json"},
               {"user-agent", user_agent()}
             ]
    end
  end

  describe "url_path/1" do
    test "prefixes the API version" do
      request = Request.new(:retrieve_refund, :get, ["refunds", "re_1"], %{})
      assert Request.url_path(request) == "/v1/refunds/re_1"
    end

    test "escapes each segment so an id cannot climb the path" do
      request =
        Request.new(:retrieve_subscription, :get, ["subscriptions", "sub_1/../customers"], %{})

      assert Request.url_path(request) == "/v1/subscriptions/sub_1%2F..%2Fcustomers"
    end
  end

  describe "new/5" do
    test "raises for a nil segment" do
      assert_raise ArgumentError, ~r/path segment/, fn ->
        Request.new(:retrieve_charge, :get, ["charges", nil], %{})
      end
    end

    test "raises for an empty segment" do
      assert_raise ArgumentError, ~r/path segment/, fn ->
        Request.new(:retrieve_charge, :get, ["charges", ""], %{})
      end
    end

    test "raises for an unknown option" do
      assert_raise ArgumentError, ~r/recv_timeout/, fn ->
        Request.new(:retrieve_charge, :get, ["charges", "ch_1"], %{}, recv_timeout: 1_000)
      end
    end

    test "defaults the timeouts" do
      assert %Request{deadline_ms: 10_000, receive_timeout: 8_000, connect_timeout: 3_000} =
               Request.new(:retrieve_charge, :get, ["charges"], %{})
    end

    test "raises for a connect timeout that leaves no time inside the deadline" do
      assert_raise ArgumentError,
                   ~r/connect_timeout \(3000\) to be less than deadline_ms \(3000\)/,
                   fn ->
                     Request.new(:retrieve_charge, :get, ["charges"], %{}, deadline_ms: 3_000)
                   end
    end

    for name <- [:deadline_ms, :receive_timeout, :connect_timeout],
        value <- [nil, 0, -1, 1.5, "1000"] do
      test "raises for #{name}: #{inspect(value)}, not a positive integer" do
        assert_raise ArgumentError,
                     ~r/expected #{unquote(name)} to be a positive integer, got: #{Regex.escape(inspect(unquote(value)))}/,
                     fn ->
                       Request.new(:retrieve_charge, :get, ["charges"], %{}, [
                         {unquote(name), unquote(value)}
                       ])
                     end
      end
    end

    test "accepts a connect timeout inside the deadline" do
      assert %Request{deadline_ms: 3_001, connect_timeout: 3_000} =
               Request.new(:retrieve_charge, :get, ["charges"], %{}, deadline_ms: 3_001)
    end

    test "keeps the default timeouts unless given" do
      request = Request.new(:retrieve_charge, :get, ["charges"], %{}, receive_timeout: 1_000)

      assert %Request{deadline_ms: 10_000, receive_timeout: 1_000, connect_timeout: 3_000} =
               request
    end
  end

  describe "body_and_query/1" do
    test "a POST sends its params as the body" do
      request = Request.new(:create_refund, :post, ["refunds"], %{charge: "ch_1", amount: 500})
      assert Request.body_and_query(request) == {"amount=500&charge=ch_1", nil}
    end

    test "a GET sends its params as the query" do
      request = Request.new(:list_refunds, :get, ["refunds"], charge: "ch_1", limit: 100)
      assert Request.body_and_query(request) == {nil, "charge=ch_1&limit=100"}
    end

    test "a DELETE sends its params as the query" do
      request =
        Request.new(:cancel_subscription, :delete, ["subscriptions", "sub_1"], prorate: true)

      assert Request.body_and_query(request) == {nil, "prorate=true"}
    end

    test "no params give no query" do
      request = Request.new(:retrieve_charge, :get, ["charges", "ch_1"], %{})
      assert Request.body_and_query(request) == {nil, nil}
    end
  end

  test "inspecting a request never shows its key" do
    request = Request.new(:create_refund, :post, ["refunds"], %{}, api_key: "sk_test_LEAK")

    refute inspect(request) =~ "LEAK"
    assert inspect(request) =~ "create_refund"
  end
end
