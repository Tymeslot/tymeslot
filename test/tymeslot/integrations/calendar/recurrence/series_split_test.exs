defmodule Tymeslot.Integrations.Calendar.Recurrence.SeriesSplitTest do
  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :integrations
  @moduletag :unit

  alias Tymeslot.Integrations.Calendar.Recurrence.SeriesSplit

  @timing {~N[2026-06-01 09:00:00], ~N[2026-06-01 10:00:00]}

  describe "count_before/4" do
    test "counts on the series' wall clock across a DST change" do
      # Mondays at 09:00 in Berlin from 1 June up to 2 November.
      assert SeriesSplit.count_before(
               "RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=30",
               @timing,
               ~N[2026-11-02 09:00:00],
               "Europe/Berlin"
             ) == {:ok, 22}
    end

    test "refuses a rule whose occurrences it would count wrongly" do
      for rule <- [
            "FREQ=MONTHLY;BYDAY=2MO;COUNT=5",
            "FREQ=MONTHLY;BYMONTHDAY=15;COUNT=5",
            "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,SU;WKST=SU;COUNT=5"
          ] do
        assert SeriesSplit.count_before(rule, @timing, ~N[2026-11-02 09:00:00], "Europe/Berlin") ==
                 {:error, :unsupported_rule},
               rule
      end
    end
  end

  describe "write/3" do
    test "creates the tail before it ends the master, and answers the tail" do
      test_pid = self()

      assert {:ok, %{"id" => "tail"}} =
               SeriesSplit.write(
                 fn ->
                   send(test_pid, :created)
                   {:ok, %{"id" => "tail"}}
                 end,
                 fn ->
                   receive do
                     :created -> {:ok, %{}}
                   after
                     0 -> flunk("the master was ended before the tail was created")
                   end
                 end,
                 fn _tail -> send(test_pid, :discard) end
               )

      refute_received :discard
    end

    test "deletes the tail again when the master cannot be ended, and reports why" do
      test_pid = self()

      assert {:error, :network_error, "boom"} =
               SeriesSplit.write(
                 fn -> {:ok, %{"id" => "tail"}} end,
                 fn -> {:error, :network_error, "boom"} end,
                 fn tail ->
                   send(test_pid, {:discard, tail})
                   :ok
                 end
               )

      assert_received {:discard, %{"id" => "tail"}}
    end

    test "writes nothing else when the tail cannot be created" do
      test_pid = self()

      assert {:error, :unauthorized, "no"} =
               SeriesSplit.write(
                 fn -> {:error, :unauthorized, "no"} end,
                 fn -> send(test_pid, :truncate) end,
                 fn _tail -> send(test_pid, :discard) end
               )

      refute_received :truncate
      refute_received :discard
    end
  end
end
