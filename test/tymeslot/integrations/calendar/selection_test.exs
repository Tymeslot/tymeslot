defmodule Tymeslot.Integrations.Calendar.SelectionTest do
  use Tymeslot.DataCase, async: true
  @moduletag :calendar

  import Ecto.Query, only: [from: 2]

  alias Tymeslot.Integrations.Calendar.Blocking
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Management
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

      assert unified.selected == true
      assert unified.id == "/dav/user%40example.org/Calendar"
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

      assert unified.selected == true
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

      assert unified.selected == false
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

      assert unified.selected == false
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

      assert unified.selected == false
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

      assert unified.id == href
      assert unified.path == href
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
      assert cal.id == encoded_path
      assert cal.path == encoded_path
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
      assert cal.id == encoded_path
      assert cal.path == encoded_path
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
      assert cal.id == href
      assert cal.path == href
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
      assert [%{path: "/cal1"}] = merged["calendar_list"]
    end

    test "primary, color, and unrecognised keys survive a full persist/re-read round trip" do
      # Regression for the write-path data loss: prepare_selected_params/2
      # used to hand-build a six-key string map, discarding primary, color,
      # and any unrecognised keys before they ever reached the database.
      user = insert(:user)
      path = "/dav/user@example.org/Calendar/"

      discovered = [
        %{
          "id" => path,
          "path" => path,
          "name" => "Calendar",
          "type" => "calendar",
          "primary" => true,
          "color" => "#123456",
          "description" => "Team calendar"
        }
      ]

      %{"calendar_list" => calendar_list} = Selection.prepare_selected_params([path], discovered)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          calendar_paths: [],
          calendar_list: []
        )

      {:ok, _updated} = Selection.persist_calendar_list(integration, calendar_list)

      {:ok, reread} = Management.get_calendar_integration(integration.id, user.id)
      [cal] = reread.calendar_list

      assert cal.primary == true
      assert cal.color == "#123456"
      assert cal.raw == %{"description" => "Team calendar"}
    end
  end

  # A reconnect writes the selection its owner just made, from the
  # integration it read before discovery went to the network.
  describe "Blocking.replace_selection/3 from a stale copy" do
    setup do
      integration =
        insert(:calendar_integration,
          user: insert(:user),
          provider: "caldav",
          calendar_list: [
            %{"id" => "/cal/a/", "path" => "/cal/a/", "name" => "A", "selected" => true},
            %{"id" => "/cal/b/", "path" => "/cal/b/", "name" => "B", "selected" => false}
          ]
        )

      %{stale: integration}
    end

    test "writes the owner's selection even where the copy already matched it", %{stale: stale} do
      # A discovery merge selects B while the owner is choosing A alone.
      {:ok, _elsewhere} =
        select_only(stale, ["/cal/a/", "/cal/b/"])

      {:ok, updated} = Blocking.replace_selection(stale, stale.calendar_list, %{})

      stored = Repo.reload!(stale)
      assert updated.calendar_paths == ["/cal/a/"]
      assert stored.calendar_paths == ["/cal/a/"]

      assert Map.new(stored.calendar_list, &{&1.id, &1.selected}) == %{
               "/cal/a/" => true,
               "/cal/b/" => false
             }
    end

    test "writes to an integration whose credentials no longer decrypt", %{stale: stale} do
      Repo.update_all(
        from(ci in CalendarIntegrationSchema,
          where: ci.id == ^stale.id
        ),
        set: [password_encrypted: :crypto.strong_rand_bytes(40)]
      )

      assert {:ok, _updated} =
               Blocking.replace_selection(stale, stale.calendar_list, %{
                 username: "alice",
                 password: "fresh"
               })

      assert {:ok, %{username: "alice", password: "fresh"}} =
               CalendarIntegrationQueries.get(stale.id)
    end
  end

  # The dashboard changes a calendar from the integration it rendered, which
  # can be older than the row: the change has to land on the row as it stands.
  describe "Blocking.set_state/3 from a stale copy" do
    setup do
      integration =
        insert(:calendar_integration,
          user: insert(:user),
          provider: "caldav",
          is_active: true,
          # Bookings go to C, so A is the owner's to switch off.
          default_booking_calendar_id: "/cal/c/",
          calendar_list: [
            %{"id" => "/cal/a/", "path" => "/cal/a/", "name" => "A", "selected" => true},
            %{"id" => "/cal/b/", "path" => "/cal/b/", "name" => "B", "selected" => false},
            %{"id" => "/cal/c/", "path" => "/cal/c/", "name" => "C", "selected" => true}
          ]
        )

      %{stale: integration}
    end

    test "keeps a choice made elsewhere since the copy was read", %{stale: stale} do
      # Another tab selects B as well.
      {:ok, _elsewhere} =
        select_only(stale, ["/cal/a/", "/cal/b/", "/cal/c/"])

      {:ok, updated} = Blocking.set_state(stale, "/cal/a/", :off)

      assert selection(updated) == %{"/cal/a/" => false, "/cal/b/" => true, "/cal/c/" => true}
    end

    test "does not re-select a calendar deselected since the copy was read", %{stale: stale} do
      # C vanished from the server and the sync deselected it.
      {:ok, _elsewhere} =
        select_only(stale, ["/cal/a/"])

      {:ok, updated} = Blocking.set_state(stale, "/cal/b/", :block)

      assert selection(updated) == %{"/cal/a/" => true, "/cal/b/" => true, "/cal/c/" => false}
    end

    defp selection(integration),
      do: Map.new(integration.calendar_list, &{&1.id, &1.selected})
  end

  # =====================================
  # Blocking.set_state/3, the live selection writer
  # =====================================

  describe "Blocking.set_state/3" do
    test "finds the calendar when the submitted id is encoded differently" do
      encoded_id = "/dav/user%40example.org/Calendar"

      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          default_booking_calendar_id: "/elsewhere/",
          calendar_list: [%{"id" => encoded_id, "name" => "Calendar", "selected" => false}]
        )

      {:ok, updated} = Blocking.set_state(integration, "/dav/user@example.org/Calendar", :block)

      assert [%CalendarEntry{selected: true}] = updated.calendar_list
    end

    test "rebuilds calendar_paths, so the sync stops touching a calendar switched off" do
      kept = "/dav/user@example.org/Calendar/"
      removed = "/dav/user@example.org/General/"

      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          default_booking_calendar_id: kept,
          calendar_paths: [kept, removed],
          calendar_list: [
            %{"id" => kept, "path" => kept, "name" => "Calendar", "selected" => true},
            %{"id" => removed, "path" => removed, "name" => "General", "selected" => true}
          ]
        )

      {:ok, updated} = Blocking.set_state(integration, removed, :off)

      assert updated.calendar_paths == [kept]
      assert Enum.find(updated.calendar_list, &(&1.id == removed)).selected == false
    end

    test "empties calendar_paths when the last synced calendar is switched off" do
      path = "/dav/user@example.org/Calendar/"
      other = "/dav/user@example.org/Bookings/"

      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          default_booking_calendar_id: other,
          calendar_paths: [path],
          calendar_list: [
            %{"id" => path, "path" => path, "name" => "Calendar", "selected" => true},
            %{"id" => other, "path" => other, "name" => "Bookings", "selected" => false}
          ]
        )

      {:ok, updated} = Blocking.set_state(integration, path, :off)

      assert updated.calendar_paths == []
    end
  end

  # =====================================
  # derive_selected_paths/1
  # =====================================

  describe "derive_selected_paths/1" do
    test "returns paths of selected entries, preserving order" do
      list = [
        %{"path" => "/a", "selected" => true},
        %{"path" => "/b", "selected" => false},
        %{"path" => "/c", "selected" => true}
      ]

      assert Selection.derive_selected_paths(list) == ["/a", "/c"]
    end

    test "tolerates atom keys and falls back to id when path is absent" do
      list = [
        %{path: "/a", selected: true},
        %{"id" => "/b", "selected" => true},
        %{"id" => "/c", "selected" => false}
      ]

      assert Selection.derive_selected_paths(list) == ["/a", "/b"]
    end

    test "skips entries with non-binary or empty paths" do
      list = [
        %{"path" => nil, "selected" => true},
        %{"path" => "", "selected" => true},
        %{"path" => "/ok", "selected" => true}
      ]

      assert Selection.derive_selected_paths(list) == ["/ok"]
    end
  end

  # =====================================
  # persist_calendar_list/2
  # =====================================

  describe "persist_calendar_list/2" do
    test "writes calendar_list and the derived calendar_paths atomically" do
      user = insert(:user)
      a = "/dav/user@example.org/Calendar/"
      b = "/dav/user@example.org/General/"

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          calendar_paths: [],
          calendar_list: []
        )

      new_list = [
        %{"id" => a, "path" => a, "name" => "Calendar", "selected" => true},
        %{"id" => b, "path" => b, "name" => "General", "selected" => false}
      ]

      {:ok, updated} = Selection.persist_calendar_list(integration, new_list)

      assert updated.calendar_paths == [a]
      assert length(updated.calendar_list) == 2
    end
  end

  describe "calendar_for_event/2" do
    @caldav_list [
      %CalendarEntry{id: "/dav/work/", path: "/dav/work/", selected: true},
      %CalendarEntry{id: "/dav/home/", path: "/dav/home/", selected: true}
    ]

    @google_list [
      %CalendarEntry{id: "me@gmail.com", primary: true, selected: true},
      %CalendarEntry{id: "team@group.calendar.google.com", selected: true}
    ]

    test "matches a CalDAV event by the collection its href lives in" do
      # The row's calendar tag disagrees with the href; the href wins.
      event = %{provider_event_id: "/dav/home/abc.ics", provider_calendar_id: "/dav/work/"}

      assert %CalendarEntry{id: "/dav/home/"} = Selection.calendar_for_event(event, @caldav_list)
    end

    test "matches any other event by the calendar the sync tagged it with" do
      event = %{
        provider_event_id: "evt-1",
        provider_calendar_id: "team@group.calendar.google.com"
      }

      assert %CalendarEntry{id: "team@group.calendar.google.com"} =
               Selection.calendar_for_event(event, @google_list)
    end

    test "returns nil for an untagged event" do
      assert Selection.calendar_for_event(%{provider_event_id: "evt-2"}, @google_list) == nil
    end

    test "returns nil without a calendar list" do
      event = %{provider_event_id: "evt-3", provider_calendar_id: "me@gmail.com"}

      assert Selection.calendar_for_event(event, nil) == nil
    end
  end

  # Another writer's selection, landed on the row as it stands: only `ids`
  # selected.
  defp select_only(integration, ids) do
    integration = Repo.reload!(integration)

    Selection.persist_calendar_list(
      integration,
      Enum.map(integration.calendar_list, &%{&1 | selected: &1.id in ids})
    )
  end
end
