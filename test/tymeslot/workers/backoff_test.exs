defmodule Tymeslot.Workers.BackoffTest do
  use ExUnit.Case, async: true

  @moduletag :workers
  @moduletag :unit

  alias Tymeslot.Workers.Backoff

  describe "ladder/2" do
    test "returns the step for each attempt and repeats the last one beyond the end" do
      assert Enum.map(1..5, &Backoff.ladder(&1, [5, 15, 45])) == [5, 15, 45, 45, 45]
    end
  end

  describe "exponential/3" do
    test "doubles the base for each attempt after the first" do
      assert Enum.map(1..4, &Backoff.exponential(&1, 30)) == [30, 60, 120, 240]
    end

    test "caps the delay" do
      assert Enum.map(1..4, &Backoff.exponential(&1, 30, 100)) == [30, 60, 100, 100]
    end
  end
end
