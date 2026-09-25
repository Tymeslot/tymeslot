defmodule Tymeslot.CalendarGrid.RecurrenceScopeTest do
  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :unit

  alias Tymeslot.CalendarGrid.RecurrenceScope

  describe "parse/1" do
    for {input, expected} <- [
          {"this_only", {:ok, :this_only}},
          {"following", {:ok, :following}},
          {"all", {:ok, :all}},
          {"All", :error},
          {"this", :error},
          {"", :error},
          {nil, :error}
        ] do
      test "reads #{inspect(input)} as #{inspect(expected)}" do
        assert RecurrenceScope.parse(unquote(input)) == unquote(Macro.escape(expected))
      end
    end

    test "reads back every scope from its own name" do
      assert Enum.map(RecurrenceScope.values(), &RecurrenceScope.parse(Atom.to_string(&1))) ==
               [{:ok, :this_only}, {:ok, :following}, {:ok, :all}]
    end
  end
end
