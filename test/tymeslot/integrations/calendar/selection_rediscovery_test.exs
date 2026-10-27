defmodule Tymeslot.Integrations.Calendar.SelectionRediscoveryTest do
  @moduledoc """
  A rediscovered calendar keeps the owner's choices, whether it is selected
  and whether it blocks availability, and a new one arrives deselected with
  the blocking default its discovery gave it.
  """
  use ExUnit.Case, async: true
  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.Selection

  describe "unify_discovered_with_existing/2" do
    test "carries a show-only choice across rediscovery, selected or not" do
      discovered = [
        %{id: "holidays", name: "Holidays"},
        %{id: "archive", name: "Archive"}
      ]

      existing = [
        %{"id" => "holidays", "selected" => true, "blocks_availability" => false},
        %{"id" => "archive", "selected" => false, "blocks_availability" => false}
      ]

      assert [holidays, archive] = Selection.unify_discovered_with_existing(discovered, existing)
      assert {holidays.selected, holidays.blocks_availability} == {true, false}
      assert {archive.selected, archive.blocks_availability} == {false, false}
    end

    test "carries a show-only choice when the server now percent-encodes the path" do
      discovered = [%{id: "/dav/user%40example.org/Rota/", path: "/dav/user%40example.org/Rota/"}]

      existing = [
        %{
          "id" => "/dav/user@example.org/Rota/",
          "path" => "/dav/user@example.org/Rota/",
          "selected" => true,
          "blocks_availability" => false
        }
      ]

      assert [rota] = Selection.unify_discovered_with_existing(discovered, existing)
      assert {rota.selected, rota.blocks_availability} == {true, false}
    end

    test "gives a newly discovered calendar the blocking default discovery gave it" do
      discovered = [
        %{id: "work", name: "Work", selected: true},
        %{id: "birthdays", name: "Birthdays", blocks_availability: false}
      ]

      assert [work, birthdays] = Selection.unify_discovered_with_existing(discovered, [])
      assert {work.selected, work.blocks_availability} == {false, true}
      assert {birthdays.selected, birthdays.blocks_availability} == {false, false}
    end
  end
end
