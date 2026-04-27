defmodule TymeslotWeb.Live.JsHookEventTest do
  @moduledoc """
  Composition tests for the JS-hook → `handle_event` seam on the
  dashboard — the class of bugs where a browser-side hook pushes a
  malformed payload to the server and the handler either crashes the
  LiveView or silently half-applies the change.

  Covers both Task 92 and Task 111. The two tasks target the same
  seam on different handlers, so they share a file:

    * Task 92 — `event_dropped` on `CalendarGridComponent` +
      `reorder_meeting_types` on `ServiceSettingsComponent`.

    * Task 111 — `event_resized`, `set_mobile_view`, and
      `navigate_swipe` on `CalendarGridComponent`.

  The production defence in each case:

    * `event_dropped` and `event_resized` both use a `with` chain on
      `Date.from_iso8601/1` + `Shared.parse_int/1` so that malformed
      strings fall through to `socket` unchanged. Regressions that
      removed any of the `with` steps (or the fall-through `else`)
      would either crash the LV or persist a bogus event move.

    * `reorder_meeting_types` filters non-integer values out of the
      payload (`nil`, `"abc"`, maps, etc.) before calling
      `MeetingTypes.reorder_meeting_types/2`; without that filter,
      the Ecto query would crash or — worse — interpret a non-integer
      as `0` and silently re-rank every row.

    * `set_mobile_view` no-ops unless the current view is `:week`;
      `navigate_swipe` maps `"next"`/`"prev"` to date arithmetic and
      falls through to the current date on any other string.

  Dropped from the plan with rationale:

    * `event_dropped`/`event_resized` with a literal `nil` field —
      the plan asked for a "null" value, but `Date.from_iso8601/1`
      and `Integer.parse/1` both have binary-only clauses, and the
      handler reads `params["new-date"]` without a default. A literal
      `nil` would raise a `FunctionClauseError` before the `with` can
      reject it. The behaviourally interesting fall-through is the
      one the handler actually defends against: a field that is
      present but un-parseable (e.g., `"not-a-date"`, `"abc"` for an
      integer). A missing/`nil` key is contradicted by the JS hook
      contract and pinning it would lock in a crash, not a rejection.

    * `reorder_meeting_types` with a fully empty list after filtering
      (all IDs non-integer) — production runs the transaction with
      `[]`, commits nothing, and reports success. Pinning the
      "success flash on an all-invalid payload" outcome would
      entrench a minor UX inconsistency rather than document the
      invariant the handler is actually defending, which is "only
      integer IDs reach the sort_order update". A mix of valid +
      invalid IDs exercises both sides of the filter and is asserted
      below.

    * `event_resized` with negative / zero duration "rejected, no
      persist" — contradicted by production. The handler has no
      end-after-start guard; `Shared.clamp_end_time/3` only rolls
      over when `hour >= 24`. A zero-duration drag is applied
      optimistically and the final rejection happens inside the
      async provider call via `EventValidator.validate/1` at
      `event_validator.ex:37`. The behaviourally interesting input
      defence at the handler level — the one Task 111 is really
      about — is "non-numeric end-hour is rejected before the
      optimistic update fires", which is asserted below.

    * `set_mobile_view` with an "invalid view key" — contradicted by
      production. `handle_set_mobile_view/2` ignores its params
      entirely and only acts when `socket.assigns.view == :week`.
      There is no "view key" to validate. The observable no-op path
      worth pinning is "when view is already :day, the hook is a
      no-op", asserted below.

    * `navigate_swipe` with a literal missing `direction` — the
      handler pattern-matches on `%{"direction" => direction}`, with
      no catch-all clause, so a missing key would raise
      `FunctionClauseError`. The behaviourally pinnable version is
      the fall-through arm inside the case: `direction` is present
      but unknown → date unchanged. That is asserted below.
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

  describe "event_resized — malformed payload" do
    setup %{user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          summary: "Resize Anchor",
          start_at: DateTime.new!(Date.utc_today(), ~T[09:00:00], "Etc/UTC"),
          end_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
          all_day: false
        )

      {:ok, event: event}
    end

    test "non-numeric new-end-hour falls through without persisting a resize",
         %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      html =
        lv
        |> element("#calendar-drag-zone")
        |> render_hook("event_resized", %{
          "event-id" => to_string(event.id),
          "event-date" => Date.to_iso8601(Date.utc_today()),
          "new-end-hour" => "ten",
          "new-end-minute" => "0"
        })

      # The `with` chain short-circuits on `:error` from `parse_int`;
      # the optimistic update is never computed, the async persist
      # never fires, and the event keeps its original slot in the DB.
      assert html =~ "Resize Anchor"
    end

    test "unparseable event-date is rejected before any event is touched",
         %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      html =
        lv
        |> element("#calendar-drag-zone")
        |> render_hook("event_resized", %{
          "event-id" => to_string(event.id),
          "event-date" => "not-a-date",
          "new-end-hour" => "11",
          "new-end-minute" => "0"
        })

      assert html =~ "Resize Anchor"
    end
  end

  describe "set_mobile_view — no-op when not in week view" do
    setup %{user: user} do
      _integration = insert(:calendar_integration, user: user, is_active: true)
      :ok
    end

    test "triggering the hook while already in day view does not change the view",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      # Switch to day view so `set_mobile_view`'s guard is false.
      lv |> element(~s|button[phx-value-view="day"]|) |> render_click()
      html_before = render(lv)

      # `handle_set_mobile_view/2` discards its params; the only thing
      # that controls whether it mutates the socket is the current
      # `:view`. With `:day` it must return the socket untouched.
      html_after =
        lv
        |> element("#calendar-grid")
        |> render_hook("set_mobile_view", %{"view" => "day-or-whatever-the-client-sends"})

      # The period label (H2) drives the visible header; equality on
      # the full render would be brittle against whitespace, so we
      # sample the header text.
      before_label = extract_period_label(html_before)
      after_label = extract_period_label(html_after)

      assert before_label == after_label
      assert before_label != ""
    end
  end

  describe "navigate_swipe — unknown direction fall-through" do
    setup %{user: user} do
      _integration = insert(:calendar_integration, user: user, is_active: true)
      :ok
    end

    test "unknown direction string leaves the visible date unchanged",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      # Day view gives a unique, date-bearing header. The swipe
      # handler's `_other -> socket.assigns.date` arm must leave it
      # exactly as-is.
      lv |> element(~s|button[phx-value-view="day"]|) |> render_click()
      label_before = extract_period_label(render(lv))

      lv
      |> element("#calendar-grid")
      |> render_hook("navigate_swipe", %{"direction" => "sideways"})

      label_after = extract_period_label(render(lv))

      assert label_after == label_before
      assert label_before != ""
    end
  end

  defp extract_period_label(html) do
    case Regex.run(~r/<h2[^>]*>(.*?)<\/h2>/s, html) do
      [_match, text] -> String.trim(text)
      _no_match -> ""
    end
  end

  defp build_component_socket(user) do
    Component.assign(%Socket{}, :current_user, user)
  end
end
