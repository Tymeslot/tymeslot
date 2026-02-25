defmodule Tymeslot.Integrations.Calendar.SelectionTest do
  use Tymeslot.DataCase, async: true
  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.Selection

  # =====================================
  # uri_safe_match?/2
  # =====================================

  describe "uri_safe_match?/2" do
    test "matches identical strings" do
      assert Selection.uri_safe_match?("/dav/user/Calendar", "/dav/user/Calendar")
    end

    test "matches percent-encoded vs decoded" do
      assert Selection.uri_safe_match?(
               "/dav/user%40example.org/Calendar",
               "/dav/user@example.org/Calendar"
             )
    end

    test "matches when both are percent-encoded" do
      assert Selection.uri_safe_match?(
               "/dav/user%40example.org/Calendar",
               "/dav/user%40example.org/Calendar"
             )
    end

    test "matches with mixed encoding (space as %20)" do
      assert Selection.uri_safe_match?("/cal/My%20Calendar", "/cal/My Calendar")
    end

    test "rejects different paths" do
      refute Selection.uri_safe_match?("/dav/user/Calendar", "/dav/other/Calendar")
    end

    test "returns false when first argument is nil" do
      refute Selection.uri_safe_match?(nil, "/dav/user/Calendar")
    end

    test "returns false when second argument is nil" do
      refute Selection.uri_safe_match?("/dav/user/Calendar", nil)
    end

    test "returns false when both arguments are nil" do
      refute Selection.uri_safe_match?(nil, nil)
    end
  end

  # =====================================
  # unify_discovered_with_existing/2
  # =====================================

  describe "unify_discovered_with_existing/2" do
    test "preserves selection when discovered ID is percent-encoded and existing is decoded" do
      discovered = [
        %{
          "id" => "/dav/user%40example.org/Calendar",
          "path" => "/dav/user%40example.org/Calendar",
          "name" => "Calendar",
          "type" => "calendar"
        }
      ]

      existing = [
        %{
          "id" => "/dav/user@example.org/Calendar",
          "path" => "/dav/user@example.org/Calendar",
          "name" => "Calendar",
          "selected" => true
        }
      ]

      [unified] = Selection.unify_discovered_with_existing(discovered, existing)

      assert unified["selected"] == true
      assert unified["id"] == "/dav/user%40example.org/Calendar"
    end

    test "preserves selection when discovered ID is decoded and existing is percent-encoded" do
      discovered = [
        %{
          "id" => "/dav/user@example.org/Calendar",
          "path" => "/dav/user@example.org/Calendar",
          "name" => "Calendar",
          "type" => "calendar"
        }
      ]

      existing = [
        %{
          "id" => "/dav/user%40example.org/Calendar",
          "path" => "/dav/user%40example.org/Calendar",
          "name" => "Calendar",
          "selected" => true
        }
      ]

      [unified] = Selection.unify_discovered_with_existing(discovered, existing)

      assert unified["selected"] == true
    end

    test "marks as unselected when no match at all" do
      discovered = [
        %{
          "id" => "/dav/other/Calendar",
          "path" => "/dav/other/Calendar",
          "name" => "Other",
          "type" => "calendar"
        }
      ]

      existing = [
        %{
          "id" => "/dav/user@example.org/Calendar",
          "path" => "/dav/user@example.org/Calendar",
          "name" => "Calendar",
          "selected" => true
        }
      ]

      [unified] = Selection.unify_discovered_with_existing(discovered, existing)

      assert unified["selected"] == false
    end
  end

  # =====================================
  # prepare_selected_params/2
  # =====================================

  describe "prepare_selected_params/2" do
    test "preserves original percent-encoded ID" do
      encoded_path = "/dav/user%40example.org/Calendar"

      discovered = [
        %{
          "id" => encoded_path,
          "path" => encoded_path,
          "name" => "Calendar",
          "type" => "calendar"
        }
      ]

      result = Selection.prepare_selected_params([encoded_path], discovered)

      [cal] = result["calendar_list"]
      assert cal["id"] == encoded_path
      assert cal["path"] == encoded_path
    end
  end
end
