defmodule Tymeslot.Availability.BusinessHoursTest do
  @moduledoc """
  Tests for the BusinessHours module.
  """

  use ExUnit.Case, async: true

  @moduletag :availability

  alias Tymeslot.Availability.BusinessHours

  describe "business_day?" do
    test "returns true for weekdays (default)" do
      # Monday to Friday
      assert BusinessHours.business_day?(~D[2026-01-12], nil)
      assert BusinessHours.business_day?(~D[2026-01-13], nil)
      assert BusinessHours.business_day?(~D[2026-01-14], nil)
      assert BusinessHours.business_day?(~D[2026-01-15], nil)
      assert BusinessHours.business_day?(~D[2026-01-16], nil)
    end

    test "returns false for weekends (default)" do
      # Saturday and Sunday
      refute BusinessHours.business_day?(~D[2026-01-17], nil)
      refute BusinessHours.business_day?(~D[2026-01-18], nil)
    end
  end

  describe "fallback_business_hours_range" do
    test "returns default range" do
      {start_time, end_time} = BusinessHours.fallback_business_hours_range()
      assert start_time == ~T[11:00:00]
      assert end_time == ~T[19:30:00]
    end
  end
end
