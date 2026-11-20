defmodule Tymeslot.Integrations.Calendar.ColourResolverTest do
  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.ColourResolver

  @target {:external, 1, "uid-1"}

  test "override wins over provider colour" do
    assert ColourResolver.resolve(%{@target => "tomato"}, @target, "blueberry") == "tomato"
  end

  test "a cleared override wins over provider colour, as no colour" do
    assert ColourResolver.resolve(%{@target => nil}, @target, "blueberry") == nil
  end

  test "provider colour used when no override" do
    assert ColourResolver.resolve(%{{:external, 1, "other"} => "tomato"}, @target, "blueberry") ==
             "blueberry"
  end

  test "nil when neither present" do
    assert ColourResolver.resolve(%{}, @target, nil) == nil
  end
end
