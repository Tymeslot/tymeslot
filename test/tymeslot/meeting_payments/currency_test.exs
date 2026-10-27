defmodule Tymeslot.MeetingPayments.CurrencyTest do
  use ExUnit.Case, async: true

  @moduletag :payments
  @moduletag :unit

  alias Tymeslot.MeetingPayments.Currency

  test "allowlist contains expected currencies" do
    assert "eur" in Currency.allowlist()
    assert "usd" in Currency.allowlist()
    assert "uah" not in Currency.allowlist()
  end

  test "allowed?/1 reflects the allowlist" do
    assert Currency.allowed?("eur")
    refute Currency.allowed?("uah")
  end

  test "allowed?/1 is false without a currency" do
    refute Currency.allowed?(nil)
  end

  describe "support/1 and chargeable?/1" do
    test "classify an account currency by whether its stored prices can be charged" do
      for {currency, support, chargeable?} <- [
            {"eur", :supported, true},
            {"ron", :legacy, true},
            {"uah", :legacy, true},
            {"jpy", :unsupported, false},
            {"kwd", :unsupported, false},
            {"", :none, false},
            {nil, :none, false}
          ] do
        assert {Currency.support(currency), Currency.chargeable?(currency)} ==
                 {support, chargeable?},
               inspect(currency)
      end
    end
  end

  test "minimum_cents returns 50 for eur" do
    assert 50 = Currency.minimum_cents("eur")
  end

  test "minimum_cents returns 17500 for huf" do
    assert 17_500 = Currency.minimum_cents("huf")
  end

  test "minimum_cents refuses a currency outside the allowlist rather than guessing" do
    assert_raise FunctionClauseError, fn -> Currency.minimum_cents("jpy") end
  end
end
