defmodule TymeslotWeb.Dashboard.Calendar.UndoStackTest do
  @moduledoc "The new calendar's undo stack: newest first, bounded, and prunable."

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :unit

  alias TymeslotWeb.Dashboard.Calendar.UndoStack

  test "pops the newest change first, and nothing when empty" do
    stack = UndoStack.new() |> UndoStack.push(%{id: 1}) |> UndoStack.push(%{id: 2})

    assert {%{id: 2}, stack} = UndoStack.pop(stack)
    assert {%{id: 1}, stack} = UndoStack.pop(stack)
    assert {nil, []} = UndoStack.pop(stack)
  end

  test "keeps only the most recent changes" do
    stack = Enum.reduce(1..30, UndoStack.new(), &UndoStack.push(&2, %{id: &1}))

    assert length(stack) == UndoStack.limit()
    assert {%{id: 30}, _rest} = UndoStack.pop(stack)
  end

  test "drops the changes that can no longer be undone" do
    stack =
      UndoStack.new()
      |> UndoStack.push(%{id: 1, key: :a})
      |> UndoStack.push(%{id: 2, key: :b})
      |> UndoStack.drop(&(&1.key == :a))

    assert stack == [%{id: 2, key: :b}]
  end
end
