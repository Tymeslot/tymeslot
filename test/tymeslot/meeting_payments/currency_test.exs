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

  test "minimum_cents returns 50 for eur" do
    assert 50 = Currency.minimum_cents("eur")
  end

  test "minimum_cents returns 17500 for huf" do
    assert 17_500 = Currency.minimum_cents("huf")
  end

  test "minimum_cents falls back to 50 for unknown" do
    assert 50 = Currency.minimum_cents("xxx")
  end
end
