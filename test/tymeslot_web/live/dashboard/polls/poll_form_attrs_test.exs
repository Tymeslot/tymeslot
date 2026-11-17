defmodule TymeslotWeb.Dashboard.Polls.PollFormAttrsTest do
  use ExUnit.Case, async: true

  alias TymeslotWeb.Dashboard.Polls.{PollFormAttrs, PollReminders}

  @moduletag :polls
  @moduletag :unit

  @assigns %{
    timezone: "Europe/London",
    duration: "30",
    notify_on_vote: true,
    reminder_picker: PollReminders.new([%{value: 1, unit: "days"}]),
    invitees: "",
    access: "anyone",
    access_chosen?: false
  }

  describe "attrs/2" do
    test "orders the rows by the counter the form issued, a forged key last" do
      params = %{
        "title" => "Planning",
        "slots" => %{
          "x1" => "2030-01-07T08:00",
          "10" => "2030-01-07T10:00",
          "2" => "2030-01-07T09:00"
        }
      }

      assert %{slots: slots} = PollFormAttrs.attrs(params, @assigns)

      assert Enum.map(slots, & &1.start_time) == [
               ~U[2030-01-07 09:00:00Z],
               ~U[2030-01-07 10:00:00Z],
               ~U[2030-01-07 08:00:00Z]
             ]
    end

    test "converts the rows and deadline from the params' timezone, dropping unfinished rows" do
      params = %{
        "timezone" => "America/New_York",
        "deadline" => "2030-01-06T12:00",
        "slots" => %{"1" => "2030-01-07T09:00", "2" => ""}
      }

      attrs = PollFormAttrs.attrs(params, @assigns)

      assert attrs.timezone == "America/New_York"
      assert attrs.deadline_at == ~U[2030-01-06 17:00:00Z]
      assert attrs.slots == [%{start_time: ~U[2030-01-07 14:00:00Z]}]
    end

    test "falls back to the assigns for the duration, timezone and vote notification" do
      attrs = PollFormAttrs.attrs(%{}, %{@assigns | duration: "45", notify_on_vote: false})

      assert attrs.duration_minutes == 45
      assert attrs.timezone == "Europe/London"
      assert attrs.notify_on_vote == false
    end

    test "reads a blank description and meeting type as none" do
      attrs =
        PollFormAttrs.attrs(%{"description" => "", "meeting_type_id" => ""}, @assigns)

      assert attrs.description == nil
      assert attrs.meeting_type_id == nil
      assert PollFormAttrs.attrs(%{"meeting_type_id" => "12"}, @assigns).meeting_type_id == 12
    end
  end

  describe "invitees/1" do
    test "reads blank or missing invitees as nobody" do
      assert PollFormAttrs.invitees(%{"invitees" => "  \n "}) == {:ok, []}
      assert PollFormAttrs.invitees(%{}) == {:ok, []}
    end

    test "tags an invalid address with the invitees field" do
      assert {:error, {:invitees, {:invalid_addresses, ["not-an-address"]}}} =
               PollFormAttrs.invitees(%{"invitees" => "not-an-address"})
    end
  end

  describe "invitees_entered?/1" do
    test "is false for blank text and nil, true once anything is typed" do
      refute PollFormAttrs.invitees_entered?(nil)
      refute PollFormAttrs.invitees_entered?("  \n")
      assert PollFormAttrs.invitees_entered?("ada@example.com")
    end
  end
end
