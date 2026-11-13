defmodule Tymeslot.Availability.TodayTest do
  @moduledoc """
  `Tymeslot.Availability.today/1`: the host's date, read in their own
  timezone from the (frozen) clock.
  """

  use ExUnit.Case, async: true

  @moduletag :availability

  import Tymeslot.Test.ClockHelpers

  alias Tymeslot.Availability
  alias Tymeslot.Profiles

  # Late on Tuesday 3 November in UTC: already Wednesday in Auckland.
  setup do
    freeze_clock(~U[2026-11-03 20:00:00Z])
  end

  test "is the date in the host's timezone" do
    assert Availability.today(%{timezone: "Pacific/Auckland"}) == ~D[2026-11-04]
    assert Availability.today(%{timezone: "America/New_York"}) == ~D[2026-11-03]
  end

  test "uses the host default for a profile without a timezone" do
    default_today =
      ~U[2026-11-03 20:00:00Z]
      |> DateTime.shift_zone!(Profiles.get_default_timezone())
      |> DateTime.to_date()

    assert Availability.today(nil) == default_today
    assert Availability.today(%{timezone: nil}) == default_today
  end
end
