defmodule TymeslotWeb.Live.Scheduling.HandlersTest do
  @moduletag :utils
  use TymeslotWeb.ConnCase, async: true
  alias TymeslotWeb.Live.Scheduling.Handlers

  test "available_handlers/0 returns list of all handlers" do
  @moduletag :utils
    handlers = Handlers.available_handlers()
    assert length(handlers) == 4

    names = Enum.map(handlers, & &1.name)
    assert "Timezone Handler" in names
    assert "Slot Fetching Handler" in names
    assert "Form Validation Handler" in names
    assert "Booking Submission Handler" in names
  end

  test "validate_handlers/0 returns :ok" do
    assert Handlers.validate_handlers() == :ok
  end
end
