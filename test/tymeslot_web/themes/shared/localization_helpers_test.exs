defmodule TymeslotWeb.Themes.Shared.LocalizationHelpersTest do
  use ExUnit.Case, async: true

  @moduletag :themes

  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  describe "sort_meeting_types/1" do
    test "sorts by name alphabetically" do
      types = [
        %{name: "Coffee Chat", duration_minutes: 30},
        %{name: "Intro Call", duration_minutes: 15},
        %{name: "Deep Dive", duration_minutes: 60}
      ]

      result = LocalizationHelpers.sort_meeting_types(types)
      assert Enum.map(result, & &1.name) == ["Coffee Chat", "Deep Dive", "Intro Call"]
    end

    test "sorts numerically, not lexicographically (15 before 30 before 90)" do
      types = [
        %{name: "90 min session", duration_minutes: 90},
        %{name: "15 min chat", duration_minutes: 15},
        %{name: "30 min call", duration_minutes: 30}
      ]

      result = LocalizationHelpers.sort_meeting_types(types)
      assert Enum.map(result, & &1.duration_minutes) == [15, 30, 90]
    end

    test "uses duration as fallback title when name is blank" do
      types = [
        %{name: "", duration_minutes: 60},
        %{name: "", duration_minutes: 15},
        %{name: "", duration_minutes: 30}
      ]

      result = LocalizationHelpers.sort_meeting_types(types)
      assert Enum.map(result, & &1.duration_minutes) == [15, 30, 60]
    end

    test "uses duration as fallback title when name is whitespace" do
      types = [
        %{name: "  ", duration_minutes: 60},
        %{name: "\t", duration_minutes: 15}
      ]

      result = LocalizationHelpers.sort_meeting_types(types)
      assert Enum.map(result, & &1.duration_minutes) == [15, 60]
    end

    test "sorts case-insensitively" do
      types = [
        %{name: "zoom call", duration_minutes: 30},
        %{name: "Coffee Chat", duration_minutes: 30},
        %{name: "Intro", duration_minutes: 30}
      ]

      result = LocalizationHelpers.sort_meeting_types(types)
      assert Enum.map(result, & &1.name) == ["Coffee Chat", "Intro", "zoom call"]
    end

    test "returns empty list unchanged" do
      assert [] = LocalizationHelpers.sort_meeting_types([])
    end

    test "returns non-list values unchanged" do
      assert nil == LocalizationHelpers.sort_meeting_types(nil)
      assert "foo" == LocalizationHelpers.sort_meeting_types("foo")
    end

    test "handles maps missing duration_minutes by using name" do
      types = [
        %{name: "Beta", duration_minutes: 30},
        %{name: "Alpha"}
      ]

      result = LocalizationHelpers.sort_meeting_types(types)
      assert Enum.map(result, & &1.name) == ["Alpha", "Beta"]
    end

    test "handles maps missing both name and duration_minutes" do
      result =
        LocalizationHelpers.sort_meeting_types([%{id: 1}, %{name: "Call", duration_minutes: 15}])

      assert length(result) == 2
      # "Call" sorts before the fallback "Untitled" key
      assert List.first(result) == %{name: "Call", duration_minutes: 15}
      assert List.last(result) == %{id: 1}
    end

    test "preserves order for items with identical sort keys" do
      types = [
        %{name: "Call", duration_minutes: 30, id: 1},
        %{name: "Call", duration_minutes: 15, id: 2}
      ]

      result = LocalizationHelpers.sort_meeting_types(types)
      assert Enum.map(result, & &1.id) == [1, 2]
    end
  end
end
