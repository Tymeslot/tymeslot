defmodule Tymeslot.Integrations.Stripe.FormEncoderTest do
  use ExUnit.Case, async: true

  alias Tymeslot.Integrations.Stripe.FormEncoder

  @moduletag :payments
  @moduletag :unit

  test "a nested map is bracketed" do
    assert FormEncoder.encode(%{metadata: %{meeting_id: "m1"}}) == "metadata%5Bmeeting_id%5D=m1"
  end

  test "a list is indexed" do
    assert FormEncoder.encode(%{expand: ["charge", "customer"]}) ==
             "expand%5B0%5D=charge&expand%5B1%5D=customer"
  end

  test "a list of maps is indexed and bracketed" do
    params = %{
      "line_items" => [
        %{"price_data" => %{"product_data" => %{"name" => "Tea"}}, "quantity" => 1}
      ]
    }

    assert FormEncoder.encode(params) ==
             "line_items%5B0%5D%5Bprice_data%5D%5Bproduct_data%5D%5Bname%5D=Tea" <>
               "&line_items%5B0%5D%5Bquantity%5D=1"
  end

  test "a keyword list is treated as a map" do
    assert FormEncoder.encode(a: [b: 1, c: [d: 2]]) == "a%5Bb%5D=1&a%5Bc%5D%5Bd%5D=2"
  end

  test "nil is sent as an empty value" do
    assert FormEncoder.encode(%{description: nil}) == "description="
  end

  test "empty lists and maps are omitted" do
    assert FormEncoder.encode(%{expand: [], metadata: %{}, a: 1}) == "a=1"
    assert FormEncoder.encode(%{}) == ""
    assert FormEncoder.encode([]) == ""
  end

  test "booleans and atoms are stringified" do
    assert FormEncoder.encode(cancel_at_period_end: true, mode: :payment) ==
             "cancel_at_period_end=true&mode=payment"
  end

  test "values are www-form escaped" do
    params = %{
      "name" => "Tea & cake",
      "success_url" => "https://x.test/r?session_id={CHECKOUT_SESSION_ID}&x=1"
    }

    assert FormEncoder.encode(params) ==
             "name=Tea+%26+cake" <>
               "&success_url=https%3A%2F%2Fx.test%2Fr%3Fsession_id%3D%7BCHECKOUT_SESSION_ID%7D%26x%3D1"
  end

  test "string and atom keys encode identically" do
    assert FormEncoder.encode(%{"a" => %{"b" => [1]}}) == FormEncoder.encode(%{a: %{b: [1]}})
  end

  test "a struct value raises naming its path" do
    assert_raise ArgumentError, ~r/a\[b\]/, fn ->
      FormEncoder.encode(%{a: %{b: DateTime.utc_now()}})
    end
  end

  test "a tuple value raises naming its path" do
    assert_raise ArgumentError, ~r/a\[0\]/, fn -> FormEncoder.encode(%{a: [{1, 2}]}) end
  end

  test "a top-level list that is not a keyword list raises" do
    assert_raise ArgumentError, ~r/map or keyword list/, fn -> FormEncoder.encode(["x"]) end
  end
end
