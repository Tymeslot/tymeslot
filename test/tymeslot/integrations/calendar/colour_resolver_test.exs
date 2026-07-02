defmodule Tymeslot.Integrations.Calendar.ColourResolverTest do
  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.ColourResolver

  test "override wins over provider colour" do
    assert ColourResolver.resolve("tomato", "blueberry") == "tomato"
  end

  test "provider colour used when no override" do
    assert ColourResolver.resolve(nil, "blueberry") == "blueberry"
  end

  test "nil when neither present" do
    assert ColourResolver.resolve(nil, nil) == nil
  end
end
