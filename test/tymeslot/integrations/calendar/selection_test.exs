defmodule Tymeslot.Integrations.Calendar.SelectionTest do
  use Tymeslot.DataCase, async: true
  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.Selection
  alias Tymeslot.Utils.SanitizeMerge

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

    test "preserves unselected status when exact key is in map with selected: false" do
      # Guards against || short-circuiting past an explicit false — a decoded
      # variant must not shadow an exact-match false.
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
          "id" => "/dav/user@example.org/Calendar",
          "path" => "/dav/user@example.org/Calendar",
          "name" => "Calendar",
          "selected" => false
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

    test "populates path from id when discovered map omits path (CalDAV shape)" do
      # `XmlHandler.parse_calendar_discovery/2` returns atom-keyed maps with
      # `:id` (the href) and no `:path` key. Persisting `\"path\" => nil`
      # broke booking via `CalendarPathResolver`. The unifier must derive a
      # usable path from the available identifiers.
      href = "/calendars/MK43327/8538e694/"

      discovered = [
        %{
          id: href,
          href: href,
          name: "Mark AhaSend",
          color: nil,
          selected: false,
          read_only: false
        }
      ]

      [unified] = Selection.unify_discovered_with_existing(discovered, [])

      assert unified["id"] == href
      assert unified["path"] == href
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

    test "zero-selection merge does not silently erase typed calendar_paths" do
      # Regression for the selection-merge clobber: when the user submits
      # `selected_calendars: []` (zero checkboxes ticked), the component used
      # to `Map.merge(params, selection)` — which wrote `calendar_paths: []`
      # and `calendar_list: []` over whatever the user had typed. The refactor
      # to `SanitizeMerge.merge/2` drops the empty-list drop-signals so the
      # user's original calendar_paths survive through to the validator, which
      # can then surface a real form error instead of silently persisting an
      # empty selection.
      discovered = [
        %{"id" => "/cal1", "path" => "/cal1", "name" => "Cal1", "type" => "calendar"},
        %{"id" => "/cal2", "path" => "/cal2", "name" => "Cal2", "type" => "calendar"}
      ]

      params = %{
        "name" => "My Calendar",
        "provider" => "caldav",
        "url" => "https://cal.example.com",
        "username" => "u",
        "password" => "p",
        "calendar_paths" => "/user-typed-path",
        "calendar_list" => [%{"path" => "/existing", "selected" => true}]
      }

      selection = Selection.prepare_selected_params([], discovered)
      assert selection["calendar_paths"] == []
      assert selection["calendar_list"] == []

      merged = SanitizeMerge.merge(params, selection)

      assert merged["calendar_paths"] == "/user-typed-path"
      assert merged["calendar_list"] == [%{"path" => "/existing", "selected" => true}]
    end

    test "selects and persists path for CalDAV-shaped discovered entries (no :path key)" do
      # Real CalDAV discovery output omits `:path`. Selecting via the href
      # must still yield a calendar_list entry with a non-nil `path` so that
      # downstream booking via `CalendarPathResolver` succeeds.
      href = "/calendars/MK43327/8538e694/"

      discovered = [
        %{
          id: href,
          href: href,
          name: "Mark AhaSend",
          color: nil,
          selected: false,
          read_only: false
        }
      ]

      result = Selection.prepare_selected_params([href], discovered)

      assert result["calendar_paths"] == [href]
      assert [cal] = result["calendar_list"]
      assert cal["id"] == href
      assert cal["path"] == href
    end

    test "non-empty selection still wins over user-typed calendar_paths" do
      # Complement of the regression above: when the user DOES select
      # calendars, the selection's `calendar_paths`/`calendar_list` must
      # overwrite the raw form input — that's the intended happy path.
      discovered = [
        %{"id" => "/cal1", "path" => "/cal1", "name" => "Cal1", "type" => "calendar"}
      ]

      params = %{
        "calendar_paths" => "/ignored-raw-input",
        "calendar_list" => [%{"path" => "/stale", "selected" => true}]
      }

      selection = Selection.prepare_selected_params(["/cal1"], discovered)
      merged = SanitizeMerge.merge(params, selection)

      assert merged["calendar_paths"] == ["/cal1"]
      assert [%{"path" => "/cal1"}] = merged["calendar_list"]
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
