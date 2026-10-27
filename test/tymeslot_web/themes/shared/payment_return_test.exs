defmodule TymeslotWeb.Themes.Shared.PaymentReturnTest do
  use ExUnit.Case, async: true

  @moduletag :payments
  @moduletag :themes

  alias TymeslotWeb.Themes.Shared.PaymentReturn

  describe "progress/1" do
    test "a booking still waiting on its payment or on the organiser's approval is waiting" do
      assert PaymentReturn.progress(:loading) == :waiting
      assert PaymentReturn.progress(:awaiting_approval) == :waiting
    end

    test "a confirmed booking is confirmed" do
      assert PaymentReturn.progress(:confirmed) == :confirmed
    end

    test "a booking that will not go ahead has ended" do
      for outcome <- [:failed, :declined, :expired, :cancelled] do
        assert PaymentReturn.progress(outcome) == :ended, "#{outcome} should be :ended"
      end
    end
  end
end
