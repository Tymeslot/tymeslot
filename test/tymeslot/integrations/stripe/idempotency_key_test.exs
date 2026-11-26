defmodule Tymeslot.Integrations.Stripe.IdempotencyKeyTest do
  use ExUnit.Case, async: true

  alias Tymeslot.Integrations.Stripe.IdempotencyKey

  @moduletag :payments
  @moduletag :unit

  test "names the intent without an attempt" do
    assert IdempotencyKey.for_intent(:refund, 42, nil) == "tymeslot:refund:42"
  end

  test "appends a positive attempt" do
    assert IdempotencyKey.for_intent(:refund, 42, 3) == "tymeslot:refund:42:3"
  end

  test "renders UUID string ids" do
    id = "0b7a6f3e-1c52-4e0a-9f7a-2d3c4b5a6978"
    assert IdempotencyKey.for_intent(:customer, id, nil) == "tymeslot:customer:#{id}"
  end

  test "an empty id raises" do
    assert_raise ArgumentError, fn -> IdempotencyKey.for_intent(:refund, "", nil) end
  end

  test "a non-positive attempt raises" do
    assert_raise FunctionClauseError, fn -> IdempotencyKey.for_intent(:refund, 1, 0) end
  end
end
