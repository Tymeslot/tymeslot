defmodule Tymeslot.MeetingTypes.LengthsTest do
  use ExUnit.Case, async: true

  @moduletag :meeting_types

  alias Tymeslot.MeetingTypes.Lengths
  alias Tymeslot.MeetingTypes.MeetingTypeSchema, as: MeetingType

  defp type(primary, extras),
    do: %MeetingType{duration_minutes: primary, extra_lengths_minutes: extras}

  describe "offered/1" do
    test "is the type's own duration when it offers no others" do
      assert Lengths.offered(type(30, [])) == [30]
    end

    test "treats a row predating the column (NULL) like one without extras" do
      assert Lengths.offered(type(30, nil)) == [30]
    end

    test "lists every length ascending, whatever order they were entered in" do
      assert Lengths.offered(type(30, [120, 15, 60])) == [15, 30, 60, 120]
    end

    test "never lists a length twice" do
      assert Lengths.offered(type(30, [30, 60])) == [30, 60]
    end
  end

  describe "multiple?/1, offers?/2 and resolve/2" do
    test "a single-length type has nothing to choose" do
      refute Lengths.multiple?(type(30, []))
      refute Lengths.multiple?(nil)
    end

    test "a type with extras offers each of them and its own duration" do
      meeting_type = type(30, [60, 90])

      assert Lengths.multiple?(meeting_type)
      assert Lengths.offers?(meeting_type, 30)
      assert Lengths.offers?(meeting_type, 90)
      refute Lengths.offers?(meeting_type, 45)
      refute Lengths.offers?(meeting_type, "60")
    end

    test "resolve keeps an offered length and falls back to the type's own otherwise" do
      meeting_type = type(30, [60])

      assert Lengths.resolve(meeting_type, 60) == 60
      assert Lengths.resolve(meeting_type, 45) == 30
      assert Lengths.resolve(meeting_type, nil) == 30
    end
  end

  describe "parse/1" do
    test "reads the forms a length arrives in" do
      assert Lengths.parse(45) == 45
      assert Lengths.parse("45") == 45
      assert Lengths.parse("45min") == 45
      assert Lengths.parse(" 45 ") == 45
    end

    test "rejects anything else" do
      assert Lengths.parse("quick-chat") == nil
      assert Lengths.parse("0") == nil
      assert Lengths.parse("-5") == nil
      assert Lengths.parse(nil) == nil
    end
  end
end
