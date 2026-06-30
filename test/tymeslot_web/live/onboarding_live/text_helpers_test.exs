defmodule TymeslotWeb.OnboardingLive.TextHelpersTest do
  @moduledoc """
  Unit tests for TextHelpers.humanize_days/1.

  Verifies that there is a single, grammatical source of truth for
  day-count phrases across the onboarding preferences step and the
  live-preview component. Previously the two surfaces held separate,
  diverging implementations that rendered "1 days" and "60 months".
  """

  use ExUnit.Case, async: true
  @moduletag :onboarding

  alias TymeslotWeb.OnboardingLive.TextHelpers

  describe "humanize_days/1" do
    test "1 renders as singular '1 day'" do
      assert TextHelpers.humanize_days(1) == "1 day"
    end

    test "60 renders as grammatical '2 months'" do
      assert TextHelpers.humanize_days(60) == "2 months"
    end

    test "90 renders as '3 months' (the default preset)" do
      assert TextHelpers.humanize_days(90) == "3 months"
    end

    test "nil delegates to 90 and renders as '3 months'" do
      assert TextHelpers.humanize_days(nil) == "3 months"
    end

    test "a non-preset value falls through to the catch-all" do
      assert TextHelpers.humanize_days(45) == "45 days"
    end
  end
end
