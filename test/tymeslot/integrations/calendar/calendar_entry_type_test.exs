defmodule Tymeslot.Integrations.Calendar.CalendarEntryTypeTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Defaults
  alias Tymeslot.Repo

  describe "cast/1" do
    test "accepts an already-normalized struct as-is" do
      entry = %CalendarEntry{id: "a"}
      assert {:ok, ^entry} = CalendarEntry.cast(entry)
    end

    test "accepts a string-keyed map" do
      assert {:ok, %CalendarEntry{id: "a", path: "/cal/a", name: "Work"}} =
               CalendarEntry.cast(%{"id" => "a", "path" => "/cal/a", "name" => "Work"})
    end

    test "accepts an atom-keyed map, falling back to href for path" do
      assert {:ok, %CalendarEntry{id: "a", path: "/cal/a"}} =
               CalendarEntry.cast(%{id: "a", href: "/cal/a"})
    end

    test "returns :error for a non-map value" do
      assert CalendarEntry.cast("nope") == :error
      assert CalendarEntry.cast([]) == :error
    end

    test "returns :error for a foreign struct rather than raising" do
      assert CalendarEntry.cast(%URI{path: "/x"}) == :error
    end
  end

  describe "load/1" do
    test "casts a plain map the same way cast/1 does" do
      assert {:ok, %CalendarEntry{id: "a"}} = CalendarEntry.load(%{"id" => "a"})
    end

    test "returns :error for a foreign struct rather than raising" do
      assert CalendarEntry.load(%URI{path: "/x"}) == :error
    end
  end

  describe "normalize/1" do
    test "passes through an already-normalized struct" do
      entry = %CalendarEntry{id: "a"}
      assert CalendarEntry.normalize(entry) == entry
    end

    test "normalizes a plain map" do
      assert %CalendarEntry{id: "a"} = CalendarEntry.normalize(%{"id" => "a"})
    end

    test "raises a clear error for a foreign struct instead of a bare MatchError" do
      assert_raise ArgumentError, ~r/CalendarEntry/, fn ->
        CalendarEntry.normalize(%URI{path: "/x"})
      end
    end
  end

  describe "legacy six-key rows (pre-dating :primary/:color)" do
    test "load through Repo yields primary: false and color: nil, and the booking ladder falls through to selected" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          calendar_list: [
            %{
              "id" => "work",
              "path" => "/cal/work",
              "name" => "Work",
              "type" => "calendar",
              "selected" => true,
              "read_only" => false
            },
            %{
              "id" => "team",
              "path" => "/cal/team",
              "name" => "Team",
              "type" => "calendar",
              "selected" => false,
              "read_only" => false
            }
          ]
        )

      reloaded = Repo.get!(CalendarIntegrationSchema, integration.id)

      assert [
               %CalendarEntry{id: "work", selected: true, primary: false, color: nil},
               %CalendarEntry{id: "team", selected: false, primary: false, color: nil}
             ] = reloaded.calendar_list

      # No entry has `primary: true`, so the primary tier falls through —
      # exactly as it did before `:primary` existed — to the first
      # selected, writable entry.
      assert %CalendarEntry{id: "work"} =
               Defaults.default_booking_calendar(reloaded.calendar_list, nil)
    end
  end
end
