defmodule Tymeslot.Payments.PricingTest do
  @moduletag :payments
  use Tymeslot.DataCase, async: true

  alias Tymeslot.Payments.Pricing

  describe "format_price/1" do
  @moduletag :payments
    test "formats EUR correctly" do
      Application.put_env(:tymeslot, :currency, "eur")
      assert Pricing.format_price(1000) == "€10"
      assert Pricing.format_price(1050) == "€10.50"
      assert Pricing.format_price(5) == "€0.05"
      assert Pricing.format_price(0) == "€0"
      assert Pricing.format_price(-1000) == "-€10"
    end

    test "formats USD correctly" do
      Application.put_env(:tymeslot, :currency, "usd")
      assert Pricing.format_price(1000) == "$10"
      assert Pricing.format_price(1050) == "$10.50"
    end

    test "formats GBP correctly" do
      Application.put_env(:tymeslot, :currency, "gbp")
      assert Pricing.format_price(1000) == "GBP 10"
    end

    test "formats unknown currency correctly" do
      Application.put_env(:tymeslot, :currency, "jpy")
      assert Pricing.format_price(1000) == "JPY 10"
    end

    test "handles atom currency" do
      Application.put_env(:tymeslot, :currency, :eur)
      assert Pricing.format_price(1000) == "€10"
    end
  end

  describe "pricing constants" do
    setup do
      old_pricing = Application.get_env(:tymeslot, :pricing)
      Application.put_env(:tymeslot, :pricing, pro_monthly_cents: 1500, pro_annual_cents: 14_400)

      on_exit(fn ->
        if old_pricing, do: Application.put_env(:tymeslot, :pricing, old_pricing)
      end)

      :ok
    end

    test "pro_monthly_cents/0 returns configured value" do
      assert Pricing.pro_monthly_cents() == 1500
    end

    test "pro_annual_cents/0 returns configured value" do
      assert Pricing.pro_annual_cents() == 14_400
    end

    test "annual_savings_cents/0 calculates savings correctly" do
      # 1500 * 12 - 14400 = 18000 - 14400 = 3600
      assert Pricing.annual_savings_cents() == 3600
    end
  end
end
