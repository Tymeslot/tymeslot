defmodule Tymeslot.Scheduling.ThemeFlowAttendeePrefillTest do
  @moduledoc """
  The name and email a booking link carries in its URL fragment, and how they
  seed the booking form.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :bookings
  @moduletag :scheduling

  alias Tymeslot.Scheduling.ThemeFlow

  describe "attendee_prefill/1" do
    test "keeps a valid name and email, trimmed" do
      assert ThemeFlow.attendee_prefill(%{
               "name" => "  Ada Lovelace ",
               "email" => " ada@example.com\n"
             }) == %{"name" => "Ada Lovelace", "email" => "ada@example.com"}
    end

    test "strips null bytes, which PostgreSQL would refuse" do
      assert ThemeFlow.attendee_prefill(%{"name" => "Ada\x00 Lovelace"}) ==
               %{"name" => "Ada Lovelace"}
    end

    test "drops a value the booking form would refuse, keeping the other" do
      assert ThemeFlow.attendee_prefill(%{"name" => "Ada", "email" => "not-an-address"}) ==
               %{"name" => "Ada"}

      assert ThemeFlow.attendee_prefill(%{
               "name" => String.duplicate("a", 101),
               "email" => "ada@example.com"
             }) == %{"email" => "ada@example.com"}
    end

    test "ignores keys other than name and email" do
      assert ThemeFlow.attendee_prefill(%{"name" => "Ada", "message" => "Hello"}) ==
               %{"name" => "Ada"}
    end

    test "yields nothing for a non-string value or no map at all" do
      assert ThemeFlow.attendee_prefill(%{"name" => ["Ada"], "email" => %{"a" => "b"}}) == %{}
      assert ThemeFlow.attendee_prefill(nil) == %{}
      assert ThemeFlow.attendee_prefill("name=Ada") == %{}
    end
  end

  describe "build_booking_form_data/3" do
    test "overlays the prefill on a blank form" do
      assert ThemeFlow.build_booking_form_data(nil, 1, %{"email" => "ada@example.com"}) ==
               %{"name" => "", "email" => "ada@example.com", "message" => ""}
    end

    test "a reschedule starts from the booking being moved, never the prefill" do
      user = insert(:user)

      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          organizer_email: user.email,
          attendee_name: "Original Attendee",
          attendee_email: "original@example.com"
        )

      form =
        ThemeFlow.build_booking_form_data(meeting.uid, user.id, %{
          "name" => "Someone Else",
          "email" => "else@example.com"
        })

      assert form["name"] == "Original Attendee"
      assert form["email"] == "original@example.com"
    end
  end
end
