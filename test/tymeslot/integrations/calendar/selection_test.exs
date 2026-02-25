defmodule Tymeslot.Integrations.Calendar.SelectionTest do
  use Tymeslot.DataCase, async: true
  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.Selection

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

    test "preserves unselected status (selected: false) regardless of encoding" do
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
          "selected" => false
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

    test "includes calendar when selected path encoding differs from discovered path" do
      encoded_path = "/dav/user%40example.org/Calendar"
      decoded_path = "/dav/user@example.org/Calendar"

      discovered = [
        %{
          "id" => encoded_path,
          "path" => encoded_path,
          "name" => "Calendar",
          "type" => "calendar"
        }
      ]

      result = Selection.prepare_selected_params([decoded_path], discovered)

      assert length(result["calendar_list"]) == 1
      [cal] = result["calendar_list"]
      assert cal["id"] == encoded_path
      assert cal["path"] == encoded_path
    end
  end

  # =====================================
  # update_calendar_selection/2
  # =====================================

  describe "update_calendar_selection/2" do
    test "marks calendar as selected when submitted ID encoding differs from stored ID" do
      user = insert(:user)
      encoded_id = "/dav/user%40example.org/Calendar"
      decoded_id = "/dav/user@example.org/Calendar"

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_list: [
            %{"id" => encoded_id, "name" => "Calendar", "selected" => false}
          ]
        )

      {:ok, updated} =
        Selection.update_calendar_selection(integration, %{
          "selected_calendars" => [decoded_id]
        })

      [cal] = updated.calendar_list
      assert cal["selected"] == true
    end
  end
end
