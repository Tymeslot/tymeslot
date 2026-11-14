defmodule Tymeslot.Test.SuiteConfigTest do
  use ExUnit.Case, async: true

  @moduletag :dev_support
  @moduletag :unit

  alias Tymeslot.Test.SuiteConfig

  describe "unless_included/2" do
    test "skips an excluded suite that a domain sweep reaches" do
      assert SuiteConfig.unless_included(:calendar_integration, [:calendar]) ==
               "calendar_integration suite: run it with --only calendar_integration"
    end

    test "skips an excluded suite in a run with no include filter" do
      assert SuiteConfig.unless_included(:e2e, []) == "e2e suite: run it with --only e2e"
    end

    test "runs the suite when --only or --include names its tag" do
      refute SuiteConfig.unless_included(:e2e, [:e2e])
      refute SuiteConfig.unless_included(:e2e, [:auth, {:e2e, "true"}])
    end

    test "runs the suite when a test is named by line" do
      refute SuiteConfig.unless_included(:calendar_integration, [
               {:location, {"test/a_test.exs", 12}}
             ])
    end

    test "never skips a tag that is not excluded by default" do
      refute SuiteConfig.unless_included(:calendar, [:auth])
    end
  end
end
