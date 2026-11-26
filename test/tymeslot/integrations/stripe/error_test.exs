defmodule Tymeslot.Integrations.Stripe.ErrorTest do
  use ExUnit.Case, async: true

  alias Tymeslot.Integrations.Stripe.Error

  @moduletag :payments
  @moduletag :unit

  @missing_body ~s({"error":{"type":"invalid_request_error","code":"resource_missing",) <>
                  ~s("param":"id","message":"No such refund: 're_1'"}})

  describe "from_response/4" do
    test "a Stripe error body sets every field" do
      error =
        Error.from_response(404, [{"request-id", "req_1"}], @missing_body, :retrieve_refund)

      assert error == %Error{
               type: "invalid_request_error",
               code: "resource_missing",
               decline_code: nil,
               param: "id",
               message: "No such refund: 're_1'",
               status: 404,
               request_id: "req_1",
               reason: nil,
               operation: :retrieve_refund
             }
    end

    test "a card decline keeps its decline code" do
      body =
        ~s({"error":{"type":"card_error","code":"card_declined","decline_code":"insufficient_funds"}})

      assert %Error{type: "card_error", code: "card_declined", decline_code: "insufficient_funds"} =
               Error.from_response(402, [], body, :create_payment_intent)
    end

    test "an HTML body is an api_error with no message" do
      error = Error.from_response(502, [], "<html>Bad gateway</html>", :retrieve_charge)

      assert %Error{type: "api_error", status: 502, message: nil, code: nil} = error
    end

    test "an empty body is an api_error with no message" do
      assert %Error{type: "api_error", status: 500, message: nil} =
               Error.from_response(500, [], "", :retrieve_charge)
    end

    test "a key Stripe quotes back is redacted from the message" do
      body =
        ~s({"error":{"type":"invalid_request_error","message":"Invalid API Key provided: sk_test_****abcd"}})

      error = Error.from_response(401, [], body, :retrieve_charge)

      refute error.message =~ "sk_"
      refute Error.message(error) =~ "sk_"
      assert error.message =~ "Invalid API Key provided"
    end
  end

  test "unexpected_body/3 is an api_error naming the request" do
    assert Error.unexpected_body(200, [{"request-id", "req_2"}], :retrieve_charge) == %Error{
             type: "api_error",
             status: 200,
             request_id: "req_2",
             message: "unexpected response body",
             operation: :retrieve_charge
           }
  end

  describe "request_id/1" do
    test "reads the request-id header" do
      assert Error.request_id([{"content-type", "application/json"}, {"request-id", "req_3"}]) ==
               "req_3"
    end

    test "is nil without one" do
      assert Error.request_id([{"content-type", "application/json"}]) == nil
    end
  end

  test "from_transport/2 is an api_connection_error carrying the reason" do
    assert Error.from_transport(:timeout, :create_refund) == %Error{
             type: "api_connection_error",
             status: nil,
             reason: :timeout,
             operation: :create_refund
           }
  end

  describe "retryable?/1" do
    for {description, error, expected} <- [
          {"a connection error", quote(do: Error.from_transport(:closed, :op)), true},
          {"a 409", quote(do: %Error{type: "idempotency_error", status: 409}), true},
          {"a 429", quote(do: %Error{type: "invalid_request_error", status: 429}), true},
          {"a 500", quote(do: %Error{type: "api_error", status: 500}), true},
          {"a 503", quote(do: %Error{type: "api_error", status: 503}), true},
          {"a 400", quote(do: %Error{type: "invalid_request_error", status: 400}), false},
          {"a 402", quote(do: %Error{type: "card_error", status: 402}), false},
          {"a 404", quote(do: %Error{type: "invalid_request_error", status: 404}), false},
          {":missing_api_key", :missing_api_key, false}
        ] do
      test "#{description} gives #{expected}" do
        assert Error.retryable?(unquote(error)) == unquote(expected)
      end
    end
  end

  describe "resource_missing?/1" do
    test "is true by code" do
      assert Error.resource_missing?(%Error{code: "resource_missing", status: 400})
    end

    test "is true by status 404" do
      assert Error.resource_missing?(%Error{type: "invalid_request_error", status: 404})
    end

    test "is false for another error and for a non-error" do
      refute Error.resource_missing?(%Error{code: "card_declined", status: 402})
      refute Error.resource_missing?(:missing_api_key)
    end
  end

  describe "account_invalid?/1" do
    test "is true by code" do
      assert Error.account_invalid?(%Error{code: "account_invalid", status: 403})
    end

    test "is false for another 403, a missing resource and a non-error" do
      refute Error.account_invalid?(%Error{type: "invalid_request_error", status: 403})
      refute Error.account_invalid?(%Error{code: "resource_missing", status: 404})
      refute Error.account_invalid?(:missing_api_key)
    end
  end

  describe "message/1" do
    test "names the operation, type, status, request and Stripe's message" do
      error = Error.from_response(404, [{"request-id", "req_1"}], @missing_body, :retrieve_refund)

      assert Error.message(error) ==
               "Stripe retrieve_refund failed: invalid_request_error (HTTP 404, request req_1): " <>
                 "No such refund: 're_1'"
    end

    test "a transport failure names the reason" do
      assert Error.message(Error.from_transport(:timeout, :create_refund)) ==
               "Stripe create_refund failed: api_connection_error: timeout"
    end

    test "is what raising the error shows" do
      error = Error.from_transport(:closed, :create_refund)
      assert_raise Error, Error.message(error), fn -> raise error end
    end
  end
end
