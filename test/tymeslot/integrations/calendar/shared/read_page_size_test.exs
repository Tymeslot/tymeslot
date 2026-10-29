defmodule Tymeslot.Integrations.Calendar.Shared.ReadPageSizeTest do
  # The override is application config, global to every test running at once.
  use ExUnit.Case, async: false

  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.Shared.ReadPageSize

  setup do
    on_exit(fn -> Application.delete_env(:tymeslot, :calendar_read_page_size) end)
  end

  test "a read keeps its own default when nothing overrides it" do
    Application.delete_env(:tymeslot, :calendar_read_page_size)
    assert ReadPageSize.get(1000) == 1000
  end

  test "the configured size overrides every read's default" do
    Application.put_env(:tymeslot, :calendar_read_page_size, 2)
    assert ReadPageSize.get(1000) == 2
    assert ReadPageSize.get(500) == 2
  end

  test "a size that is not a positive integer is ignored" do
    Application.put_env(:tymeslot, :calendar_read_page_size, 0)
    assert ReadPageSize.get(1000) == 1000
  end
end
