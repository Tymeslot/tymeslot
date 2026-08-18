defmodule TymeslotWeb.Live.Scheduling.HandlersTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  alias TymeslotWeb.Live.Scheduling.Handlers

  test "validate_handlers/0 returns :ok" do
    assert Handlers.validate_handlers() == :ok
  end
end
