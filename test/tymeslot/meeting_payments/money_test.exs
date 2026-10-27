defmodule Tymeslot.MeetingPayments.MoneyTest do
  use ExUnit.Case, async: true

  @moduletag :payments
  @moduletag :unit

  alias Tymeslot.MeetingPayments.Money

  doctest Money

  describe "minor_units/1" do
    test "follows Stripe's zero-, two- and three-decimal currencies, in any case" do
      assert Enum.map(~w(eur gbp huf jpy KRW kwd), &Money.minor_units/1) == [2, 2, 2, 0, 0, 3]
    end
  end

  describe "parse/2" do
    @accepted [
      {"10", "eur", 1000},
      {"10.5", "eur", 1050},
      {"10,50", "eur", 1050},
      {"  7.05\n", "usd", 705},
      {"0.01", "gbp", 1},
      {"0010", "eur", 1000},
      {"1500", "jpy", 1500},
      {"1.234", "kwd", 1234},
      {"175", "huf", 17_500}
    ]

    test "reads an amount in major units into minor units" do
      for {input, currency, cents} <- @accepted do
        assert Money.parse(input, currency) == {:ok, cents}, "#{inspect(input)} #{currency}"
      end
    end

    @rejected [
      {"", "eur"},
      {"   ", "eur"},
      {"0", "eur"},
      {"0.00", "eur"},
      {"-5", "eur"},
      {"+5", "eur"},
      {"10.505", "eur"},
      {"10.5", "jpy"},
      {"1e3", "eur"},
      {"1,000.00", "eur"},
      {"10.", "eur"},
      {".5", "eur"},
      {"10 50", "eur"},
      {"€10", "eur"},
      {"١٠", "eur"}
    ]

    test "rejects anything but a positive amount with the currency's decimals" do
      for {input, currency} <- @rejected do
        assert Money.parse(input, currency) == {:error, :invalid_amount},
               "#{inspect(input)} #{currency}"
      end
    end

    test "rejects a value that is not a string" do
      assert Money.parse(10, "eur") == {:error, :invalid_amount}
      assert Money.parse(nil, "eur") == {:error, :invalid_amount}
    end
  end

  describe "to_major_string/2" do
    test "writes minor units as a plain decimal in major units" do
      assert Money.to_major_string(1050, "eur") == "10.50"
      assert Money.to_major_string(5, "eur") == "0.05"
      assert Money.to_major_string(-1050, "eur") == "-10.50"
      assert Money.to_major_string(1500, "jpy") == "1500"
      assert Money.to_major_string(1234, "kwd") == "1.234"
    end

    test "round-trips through parse/2" do
      for {_input, currency, cents} <- @accepted do
        assert Money.parse(Money.to_major_string(cents, currency), currency) == {:ok, cents}
      end
    end
  end

  describe "format/3" do
    @formatted [
      {1050, "eur", [], "€10.50"},
      {1000, "gbp", [], "£10.00"},
      {1000, "GBP", [], "£10.00"},
      {-1000, "eur", [], "-€10.00"},
      {0, "usd", [], "$0.00"},
      {99, "usd", [], "$0.99"},
      {123_456, "cad", [], "CA$1234.56"},
      {1000, "chf", [], "CHF 10.00"},
      {17_500, "huf", [], "HUF 175.00"},
      {1500, "jpy", [], "¥1500"},
      {1234, "kwd", [], "KWD 1.234"},
      {1000, "eur", [trim_zero_minor: true], "€10"},
      {-500, "eur", [trim_zero_minor: true], "-€5"},
      {1050, "eur", [trim_zero_minor: true], "€10.50"},
      {1500, "jpy", [trim_zero_minor: true], "¥1500"}
    ]

    test "writes the symbol or code, then the amount, with the sign in front" do
      for {cents, currency, opts, expected} <- @formatted do
        assert Money.format(cents, currency, opts) == expected,
               "#{cents} #{currency} #{inspect(opts)}"
      end
    end
  end
end
