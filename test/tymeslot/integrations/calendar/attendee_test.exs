defmodule Tymeslot.Integrations.Calendar.AttendeeTest do
  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.Attendee

  doctest Attendee

  describe "new/1" do
    test "leaves the reply unset for an attendee given only an address" do
      assert Attendee.new(email: "ada@example.com") == %{
               email: "ada@example.com",
               display_name: nil,
               response_status: nil,
               optional: false
             }
    end

    test "keeps every field it is given" do
      assert Attendee.new(%{
               email: "ada@example.com",
               display_name: "Ada Lovelace",
               response_status: :accepted,
               optional: true
             }) == %{
               email: "ada@example.com",
               display_name: "Ada Lovelace",
               response_status: :accepted,
               optional: true
             }
    end

    test "rejects a field outside the canonical shape" do
      assert_raise ArgumentError, ~r/unknown keys \[:name\]/, fn ->
        Attendee.new(email: "ada@example.com", name: "Ada")
      end
    end
  end

  describe "normalise/1" do
    test "reads a string-keyed row as the JSONB column returns it" do
      row = %{
        "email" => "ada@example.com",
        "display_name" => "Ada Lovelace",
        "response_status" => "declined",
        "optional" => true
      }

      assert Attendee.normalise(row) == %{
               email: "ada@example.com",
               display_name: "Ada Lovelace",
               response_status: :declined,
               optional: true
             }
    end

    test "returns a canonical attendee unchanged" do
      attendee =
        Attendee.new(
          email: "ada@example.com",
          display_name: "Ada",
          response_status: :tentative,
          optional: false
        )

      assert Attendee.normalise(attendee) == attendee
    end

    test "survives a JSON round trip of what new/1 built" do
      attendee = Attendee.new(email: "ada@example.com", response_status: :needs_action)
      round_tripped = attendee |> Jason.encode!() |> Jason.decode!()

      assert Attendee.normalise(round_tripped) == attendee
    end

    test "reads every reply the providers report" do
      for {stored, expected} <- [
            {"accepted", :accepted},
            {"declined", :declined},
            {"tentative", :tentative},
            {"needs_action", :needs_action}
          ] do
        assert Attendee.normalise(%{"response_status" => stored}).response_status == expected
      end
    end

    test "keeps an absent reply absent, whether the key is missing or null" do
      assert Attendee.normalise(%{"email" => "ada@example.com"}).response_status == nil

      assert Attendee.normalise(%{"email" => "ada@example.com", "response_status" => nil}).response_status ==
               nil
    end

    test "folds a reply it does not recognise to needs_action" do
      assert Attendee.normalise(%{"response_status" => "delegated"}).response_status ==
               :needs_action
    end

    test "reads the legacy name spelling as the display name" do
      assert Attendee.normalise(%{"email" => "ada@example.com", "name" => "Ada"}).display_name ==
               "Ada"

      assert Attendee.normalise(%{email: "ada@example.com", name: "Ada"}).display_name == "Ada"
    end

    test "prefers display_name over the legacy name" do
      attendee = %{"display_name" => "Ada Lovelace", "name" => "Ada"}
      assert Attendee.normalise(attendee).display_name == "Ada Lovelace"
    end

    test "ignores the status key the grid once wrote" do
      legacy = %{"email" => "ada@example.com", "name" => nil, "status" => "accepted"}

      assert Attendee.normalise(legacy) == %{
               email: "ada@example.com",
               display_name: nil,
               response_status: nil,
               optional: false
             }
    end

    test "reads only a true flag as optional" do
      assert Attendee.normalise(%{"optional" => "true"}).optional == true
      assert Attendee.normalise(%{"optional" => nil}).optional == false
      assert Attendee.normalise(%{}).optional == false
    end
  end
end
