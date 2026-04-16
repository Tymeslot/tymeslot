defmodule Tymeslot.Integrations.Calendar.CalDAV.ConflictResolutionTest do
  use ExUnit.Case, async: true

  @moduletag :integrations
  @moduletag :unit

  alias Tymeslot.Integrations.Calendar.CalDAV.ConflictResolution

  describe "default/0" do
    test "returns :fail" do
      assert ConflictResolution.default() == :fail
    end
  end

  describe "valid?/1" do
    test "returns true for :fail" do
      assert ConflictResolution.valid?(:fail)
    end

    test "returns true for :keep_server" do
      assert ConflictResolution.valid?(:keep_server)
    end

    test "returns true for :keep_local" do
      assert ConflictResolution.valid?(:keep_local)
    end

    test "returns false for an unknown policy" do
      refute ConflictResolution.valid?(:unknown_policy)
    end
  end
end
