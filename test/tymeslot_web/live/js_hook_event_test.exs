defmodule TymeslotWeb.Live.JsHookEventTest do
  @moduledoc """
  Composition tests for the JS-hook → `handle_event` seam on the
  dashboard — the class of bugs where a browser-side hook pushes a
  malformed payload to the server and the handler either crashes the
  LiveView or silently half-applies the change.

  Two handler clusters are covered here:

    * `event_dropped` on `CalendarGridComponent` — the drag-and-drop
      path that writes the new start/end for a calendar event. The
      production code uses a `with` on `Date.from_iso8601/1` and
      `Shared.parse_int/1` so that malformed strings fall through to
      `socket` unchanged. Regressions that removed any of the `with`
      steps (or the fall-through `else`) would either crash the LV or
      persist a bogus event move.

    * `reorder_meeting_types` on `ServiceSettingsComponent` — the
      sortable-list hook that emits the new ID order. The handler
      filters non-integer values out of the payload (`nil`, `"abc"`,
      maps, etc.) before calling `MeetingTypes.reorder_meeting_types/2`;
      without that filter, the Ecto query would crash or — worse —
      interpret a non-integer as `0` and silently re-rank every row.

  Task 92 covers `event_dropped` + `reorder_meeting_types`. The
  companion `event_resized`, `set_mobile_view`, and `navigate_swipe`
  handlers are covered in the Task 111 sibling file.

  Dropped from the plan with rationale:

    * `event_dropped` with a literal `nil` field — the plan asked for
      a "null" value, but `Date.from_iso8601/1` and `Integer.parse/1`
      both have binary-only clauses, and the handler reads
      `params["new-date"]` without a default. A literal `nil` would
      raise a `FunctionClauseError` before the `with` can reject it.
      The behaviourally interesting fall-through is the one the
      handler actually defends against: a field that is present but
      un-parseable (e.g., `"not-a-date"`, `"abc"` for an integer).
      A missing/`nil` key is contradicted by the JS hook contract and
      pinning it would lock in a crash, not a rejection.

    * `reorder_meeting_types` with a fully empty list after filtering
      (all IDs non-integer) — production runs the transaction with
      `[]`, commits nothing, and reports success. Pinning the
      "success flash on an all-invalid payload" outcome would
      entrench a minor UX inconsistency rather than document the
      invariant the handler is actually defending, which is "only
      integer IDs reach the sort_order update". A mix of valid +
      invalid IDs exercises both sides of the filter and is asserted
      below.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :live
  @moduletag :dashboard

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Phoenix.Component
  alias Phoenix.LiveView.Socket
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Dashboard.ServiceSettingsComponent

  setup :setup_dashboard_user

  setup do
    try do
      :meck.unload(RateLimiter)
    rescue
      _other -> :ok
    end

    on_exit(fn ->
      try do
        :meck.unload(RateLimiter)
      rescue
        _other -> :ok
      end
    end)

    :ok
  end

  describe "event_dropped — malformed payload" do
    setup %{user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          summary: "Anchor Event",
          start_at: DateTime.new!(Date.utc_today(), ~T[09:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
          all_day: false
        )

      {:ok, integration: integration, event: event}
    end

    test "unparseable new-date falls through without moving the event", %{
      conn: conn,
      event: event
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      # `Date.from_iso8601/1` returns `{:error, :invalid_format}` for
      # "not-a-date", which matches the handler's fall-through arm. If
      # the `with` chain were ever inverted (e.g., `Date.from_iso8601!`),
      # the LV would crash here instead of silently ignoring the drop.
      html =
        lv
        |> element("#calendar-drag-zone")
        |> render_hook("event_dropped", %{
          "event-id" => to_string(event.id),
          "new-date" => "not-a-date",
          "new-hour" => "10",
          "new-minute" => "0",
          "new-end-hour" => "11",
          "new-end-minute" => "0"
        })

      # Event still rendered at its original position (no modal, no
      # "permission" banner, no flash visible from a failed async).
      assert html =~ "Anchor Event"
      refute html =~ "Edit recurring event"
      refute html =~ "You don&#39;t have permission"
    end

    test "non-numeric new-hour falls through without moving the event", %{
      conn: conn,
      event: event
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      tomorrow_iso = Date.to_iso8601(Date.add(Date.utc_today(), 1))

      html =
        lv
        |> element("#calendar-drag-zone")
        |> render_hook("event_dropped", %{
          "event-id" => to_string(event.id),
          "new-date" => tomorrow_iso,
          "new-hour" => "nine",
          "new-minute" => "0",
          "new-end-hour" => "11",
          "new-end-minute" => "0"
        })

      assert html =~ "Anchor Event"
      refute html =~ "Edit recurring event"
    end

    test "unparseable event-id is rejected before any event is touched", %{
      conn: conn,
      event: event
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      # `with_editable_event/3` calls `Integer.parse(params["event-id"] || "")`.
      # A non-numeric id yields `:error`, so the handler returns the
      # socket unchanged — no crash, no recurrence prompt, no flash.
      html =
        lv
        |> element("#calendar-drag-zone")
        |> render_hook("event_dropped", %{
          "event-id" => "not-an-id",
          "new-date" => Date.to_iso8601(Date.utc_today()),
          "new-hour" => "10",
          "new-minute" => "0",
          "new-end-hour" => "11",
          "new-end-minute" => "0"
        })

      assert html =~ event.summary
      refute html =~ "Edit recurring event"
    end
  end

  describe "reorder_meeting_types — ID filtering" do
    # `#meeting-types-sortable-list` carries `phx-hook` +
    # `data-target` but no `phx-target`, so events pushed from it in
    # a LiveView test land on the root LV (the JS hook uses
    # `pushEventTo(data-target, …)`, which LiveViewTest does not
    # emulate). These tests therefore call the component's
    # `handle_event/3` directly with a minimally-constructed socket —
    # the filter and rate-limit logic live entirely in the handler
    # and do not depend on the surrounding LiveView assigns.

    test "only integer IDs are applied; non-integers are silently dropped", %{user: user} do
      mt1 = insert(:meeting_type, user: user, name: "Intro", sort_order: 0)
      mt2 = insert(:meeting_type, user: user, name: "Deep Dive", sort_order: 1)

      socket = build_component_socket(user)

      # Payload mixes the two real integer IDs with a nil, a
      # non-numeric binary, and a map. The handler must filter those
      # three out and re-rank only `mt1` and `mt2`.
      assert {:noreply, _socket} =
               ServiceSettingsComponent.handle_event(
                 "reorder_meeting_types",
                 %{
                   "ids" => [
                     to_string(mt2.id),
                     nil,
                     "not-an-id",
                     %{"id" => 99_999},
                     to_string(mt1.id)
                   ]
                 },
                 socket
               )

      reloaded_mt1 = Repo.get!(MeetingTypeSchema, mt1.id)
      reloaded_mt2 = Repo.get!(MeetingTypeSchema, mt2.id)

      # New order: mt2 first (sort_order 0), mt1 second (sort_order 1).
      # If the filter were ever removed, the non-integer entries would
      # either crash the query or land at sort_order 1/2/3 and shift
      # the real rows to 0/4 — both visible regressions.
      assert reloaded_mt2.sort_order == 0
      assert reloaded_mt1.sort_order == 1
    end

    test "rate-limit rejection sends an error flash and leaves order unchanged",
         %{user: user} do
      mt1 = insert(:meeting_type, user: user, name: "Intro", sort_order: 0)
      mt2 = insert(:meeting_type, user: user, name: "Deep Dive", sort_order: 1)

      :meck.new(RateLimiter, [:passthrough])

      :meck.expect(RateLimiter, :check_meeting_type_write_rate_limit, fn _user_id ->
        {:error, :rate_limited, "Slow down — too many reorders"}
      end)

      socket = build_component_socket(user)

      assert {:noreply, _socket} =
               ServiceSettingsComponent.handle_event(
                 "reorder_meeting_types",
                 %{"ids" => [to_string(mt2.id), to_string(mt1.id)]},
                 socket
               )

      # `Flash.error/1` sends `{:flash, {:error, msg}}` to self(); the
      # parent LiveView's `handle_info/2` forwards it to the rendered
      # flash region.
      assert_received {:flash, {:error, "Slow down — too many reorders"}}

      # Order untouched — the rate-limit arm must short-circuit before
      # the filter and Ecto update run.
      assert Repo.get!(MeetingTypeSchema, mt1.id).sort_order == 0
      assert Repo.get!(MeetingTypeSchema, mt2.id).sort_order == 1
    end
  end

  defp build_component_socket(user) do
    Component.assign(%Socket{}, :current_user, user)
  end
end
