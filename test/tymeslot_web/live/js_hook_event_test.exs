defmodule TymeslotWeb.Live.JsHookEventTest do
  @moduledoc """
  Composition tests for the JS-hook → `handle_event` seam on the
  dashboard: a browser-side hook pushes a malformed payload and the handler
  must neither crash nor half-apply the change.

  `reorder_meeting_types` on `ServiceSettingsComponent` filters non-integer
  values out of the payload (`nil`, `"abc"`, maps) before calling
  `MeetingTypes.reorder_meeting_types/2`; without that filter the Ecto query
  would crash or interpret a non-integer as `0` and re-rank every row.

  The calendar's own payload guards are covered on the calendar surface
  (`CalendarSurfaceMoveTest`, "a change the calendar refuses snaps back and
  writes nothing"; `CalendarSurfaceDeleteTest`, "malformed payloads change
  nothing and crash nothing").
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :live
  @moduletag :dashboard

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory
  import Tymeslot.RateLimiterTestHelpers, only: [exhaust_limit!: 2]

  alias Phoenix.Component
  alias Phoenix.LiveView.Socket
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Repo
  alias TymeslotWeb.Dashboard.ServiceSettingsComponent
  alias TymeslotWeb.Hooks.ModalHook

  setup :setup_dashboard_user

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

      refusal = exhaust_limit!(:meeting_type_write, user.id)

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
      assert_received {:flash, {:error, ^refusal}}

      # Order untouched — the rate-limit arm must short-circuit before
      # the filter and Ecto update run.
      assert Repo.get!(MeetingTypeSchema, mt1.id).sort_order == 0
      assert Repo.get!(MeetingTypeSchema, mt2.id).sort_order == 1
    end
  end

  describe "ServiceSettingsComponent — meeting_type_write rate limit" do
    setup %{user: user} do
      {:ok,
       mt: insert(:meeting_type, user: user, name: "Intro", is_active: true, is_private: false)}
    end

    test "toggle_type is refused and leaves the status unchanged", %{user: user, mt: mt} do
      refusal = exhaust_limit!(:meeting_type_write, user.id)

      socket =
        user
        |> build_component_socket()
        |> Component.assign(toggling_type_id: nil, meeting_types: [mt])

      assert {:noreply, _socket} =
               ServiceSettingsComponent.handle_event(
                 "toggle_type",
                 %{"id" => to_string(mt.id)},
                 socket
               )

      assert_received {:flash, {:error, ^refusal}}
      assert Repo.get!(MeetingTypeSchema, mt.id).is_active
    end

    test "toggle_private is refused and leaves the visibility unchanged", %{user: user, mt: mt} do
      refusal = exhaust_limit!(:meeting_type_write, user.id)

      assert {:noreply, _socket} =
               ServiceSettingsComponent.handle_event(
                 "toggle_private",
                 %{"id" => to_string(mt.id), "listed" => "false"},
                 build_component_socket(user)
               )

      assert_received {:flash, {:error, ^refusal}}
      refute Repo.get!(MeetingTypeSchema, mt.id).is_private
    end

    test "confirm_slug_change is refused and leaves the slug unchanged", %{user: user, mt: mt} do
      refusal = exhaust_limit!(:meeting_type_write, user.id)

      socket =
        user
        |> build_component_socket()
        |> ModalHook.show_modal(:slug, mt)
        |> Component.assign(:slug_draft, "a-brand-new-slug")

      assert {:noreply, _socket} =
               ServiceSettingsComponent.handle_event("confirm_slug_change", %{}, socket)

      assert_received {:flash, {:error, ^refusal}}
      assert Repo.get!(MeetingTypeSchema, mt.id).slug == mt.slug
    end

    test "confirm_delete_meeting_type is refused and keeps the meeting type", %{
      user: user,
      mt: mt
    } do
      refusal = exhaust_limit!(:meeting_type_write, user.id)

      socket =
        user
        |> build_component_socket()
        |> ModalHook.show_modal(:delete_meeting_type, mt)

      assert {:noreply, _socket} =
               ServiceSettingsComponent.handle_event("confirm_delete_meeting_type", %{}, socket)

      assert_received {:flash, {:error, ^refusal}}
      assert Repo.get(MeetingTypeSchema, mt.id)
    end
  end

  defp build_component_socket(user) do
    Component.assign(%Socket{}, :current_user, user)
  end
end
