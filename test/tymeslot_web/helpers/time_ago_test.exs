defmodule TymeslotWeb.Helpers.TimeAgoTest do
  use ExUnit.Case, async: true

  @moduletag :dashboard
  @moduletag :unit

  alias TymeslotWeb.Helpers.TimeAgo

  @now ~U[2026-10-09 12:00:00Z]

  test "names how long ago in the largest whole unit" do
    assert TimeAgo.since(~U[2026-10-09 11:59:30Z], @now) == :just_now
    assert TimeAgo.since(~U[2026-10-09 11:59:00Z], @now) == {:minutes, 1}
    assert TimeAgo.since(~U[2026-10-09 11:01:00Z], @now) == {:minutes, 59}
    assert TimeAgo.since(~U[2026-10-09 10:00:00Z], @now) == {:hours, 2}
    assert TimeAgo.since(~U[2026-10-06 12:00:00Z], @now) == {:days, 3}
  end

  test "a moment ahead of now is just now" do
    assert TimeAgo.since(~U[2026-10-09 12:05:00Z], @now) == :just_now
  end
end
