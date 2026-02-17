defmodule Tymeslot.Payments.Webhooks.PaymentMethodHandlerTest do
  use ExUnit.Case, async: true

  alias Tymeslot.Payments.Webhooks.PaymentMethodHandler

  describe "can_handle?/1" do
    test "returns true for supported payment method events" do
      assert PaymentMethodHandler.can_handle?("payment_method.attached")
    end

    test "returns false for unsupported events" do
      refute PaymentMethodHandler.can_handle?("payment_method.detached")
    end
  end

  describe "validate/1" do
    test "returns :ok for valid payment method" do
      assert PaymentMethodHandler.validate(%{"id" => "pm_123"}) == :ok
    end

    test "returns error for missing or empty id" do
      assert {:error, :missing_field, _message} = PaymentMethodHandler.validate(%{})
      assert {:error, :missing_field, _message} = PaymentMethodHandler.validate(%{"id" => ""})
    end
  end

  describe "process/2" do
    test "acknowledges payment method attachment" do
      payment_method = %{"id" => "pm_123", "customer" => "cus_123"}
      event = %{"type" => "payment_method.attached"}

      assert {:ok, :payment_method_processed} =
               PaymentMethodHandler.process(event, payment_method)
    end
  end
end
