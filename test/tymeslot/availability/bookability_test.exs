defmodule Tymeslot.Availability.BookabilityTest do
  @moduledoc """
  `Bookability`: the rule for whether a calendar event stops guests booking
  its time, and the organiser's per-event overrides. Overrides are reached
  only through an integration the user owns, replace each other, and tell
  the booking page and the calendar at once.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :availability
  @moduletag :calendar

  alias Ecto.Changeset
  alias Tymeslot.Availability
  alias Tymeslot.Availability.Bookability
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.EventRole
  alias Tymeslot.Integrations.Calendar.IntegrationCacheQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Repo

  setup do
    user = insert(:user)
    integration = insert(:calendar_integration, user: user, provider: "google")
    %{user: user, integration: integration}
  end

  defp event(attrs) do
    struct!(
      %CalendarEvent{
        uid: "event-1",
        calendar_integration_id: 1,
        provider: :google,
        provider_calendar_id: "holidays",
        all_day: true,
        start_date: ~D[2026-12-25],
        end_date: ~D[2026-12-26],
        synced_at: ~U[2026-10-01 00:00:00Z],
        transparency: :transparent
      },
      attrs
    )
  end

  describe "busy_for_bookings?/2" do
    test "without an override, a free all-day event is free" do
      refute Bookability.busy_for_bookings?(event(%{}), %{})
    end

    test "without an override, a busy all-day event is busy" do
      assert Bookability.busy_for_bookings?(event(%{transparency: :opaque}), %{})
    end

    test "a cancelled all-day event is free" do
      refute Bookability.busy_for_bookings?(
               event(%{transparency: :opaque, status: :cancelled}),
               %{}
             )
    end

    test "an override on an all-day event wins either way" do
      free = event(%{})
      busy = event(%{transparency: :opaque})

      assert Bookability.busy_for_bookings?(free, %{{1, "event-1"} => true})
      refute Bookability.busy_for_bookings?(busy, %{{1, "event-1"} => false})
    end

    test "an override on a timed event does not reach bookings" do
      timed =
        event(%{
          all_day: false,
          start_date: nil,
          end_date: nil,
          start_at: ~U[2026-12-25 10:00:00Z],
          end_at: ~U[2026-12-25 11:00:00Z]
        })

      refute Bookability.busy_for_bookings?(timed, %{{1, "event-1"} => true})
    end
  end

  describe "set/4, clear/3 and for_user/1" do
    test "stores the choice, and a second choice replaces the first", ctx do
      assert :ok = Bookability.set(ctx.user.id, ctx.integration.id, "h-1", false)
      assert Bookability.for_user(ctx.user.id) == %{{ctx.integration.id, "h-1"} => false}

      assert :ok = Bookability.set(ctx.user.id, ctx.integration.id, "h-1", true)
      assert Bookability.for_user(ctx.user.id) == %{{ctx.integration.id, "h-1"} => true}
    end

    test "clear goes back to the rule", ctx do
      :ok = Bookability.set(ctx.user.id, ctx.integration.id, "h-1", false)

      assert :ok = Bookability.clear(ctx.user.id, ctx.integration.id, "h-1")
      assert Bookability.for_user(ctx.user.id) == %{}
    end

    test "refuses another user's integration and stores nothing", ctx do
      other = insert(:calendar_integration, provider: "google")

      assert {:error, :not_found} = Bookability.set(ctx.user.id, other.id, "h-1", false)
      assert {:error, :not_found} = Bookability.clear(ctx.user.id, other.id, "h-1")
      assert Bookability.for_user(ctx.user.id) == %{}
    end

    test "refuses an empty uid", ctx do
      assert {:error, %Changeset{}} = Bookability.set(ctx.user.id, ctx.integration.id, "", true)
    end

    test "each write tells the booking page and the calendar", ctx do
      :ok = Availability.subscribe(ctx.user.id)

      :ok = Bookability.set(ctx.user.id, ctx.integration.id, "h-1", false)
      assert_receive {:availability_changed, user_id} when user_id == ctx.user.id

      :ok = Bookability.clear(ctx.user.id, ctx.integration.id, "h-1")
      assert_receive {:availability_changed, user_id} when user_id == ctx.user.id
    end
  end

  describe "a choice on an event that is gone" do
    setup ctx do
      for uid <- ["gone", "kept"] do
        insert(:provider_calendar_event,
          calendar_integration: ctx.integration,
          uid: uid,
          provider_event_id: "evt-" <> uid,
          all_day: true,
          start_at: nil,
          end_at: nil,
          start_date: ~D[2026-12-25],
          end_date: ~D[2026-12-26],
          transparency: "transparent"
        )

        :ok = Bookability.set(ctx.user.id, ctx.integration.id, uid, false)
      end

      :ok
    end

    test "goes when a sync reports the event deleted, and another event's stays", ctx do
      :ok = Sync.reconcile_deletions(ctx.integration, [%{uid: "gone", provider_event_id: nil}])

      assert Bookability.for_user(ctx.user.id) == %{{ctx.integration.id, "kept"} => false}
    end

    test "goes when the event is deleted by its provider id", ctx do
      ProviderCalendarEventQueries.delete_by_provider_event_ids(ctx.integration.id, ["evt-gone"])

      assert Bookability.for_user(ctx.user.id) == %{{ctx.integration.id, "kept"} => false}
    end

    test "goes when the event is deleted here", ctx do
      {:ok, :deleted} = ProviderCalendarEventQueries.delete_by_uid(ctx.integration.id, "gone")

      assert Bookability.for_user(ctx.user.id) == %{{ctx.integration.id, "kept"} => false}
    end

    test "goes when a feed refresh drops the event, and stays on the event it puts back", ctx do
      {:ok, 1} =
        IntegrationCacheQueries.replace_cached_rows(ctx.integration.id, :all, [
          row_attrs(ctx.integration, "kept")
        ])

      assert Bookability.for_user(ctx.user.id) == %{{ctx.integration.id, "kept"} => false}
    end

    test "stays when a refresh scoped to part of the integration leaves the event out", ctx do
      {:ok, 0} =
        IntegrationCacheQueries.replace_cached_rows(
          ctx.integration.id,
          {:role, EventRole.both()},
          []
        )

      assert map_size(Bookability.for_user(ctx.user.id)) == 2
    end

    test "stays when the sync that deleted the event fails and rolls back", ctx do
      {:error, :failed} =
        Repo.transaction(fn ->
          2 = ProviderCalendarEventQueries.delete_by_uids(ctx.integration.id, ["gone", "kept"])
          assert Bookability.for_user(ctx.user.id) == %{}
          Repo.rollback(:failed)
        end)

      assert map_size(Bookability.for_user(ctx.user.id)) == 2
    end

    test "stays when the event only ages out of the cache", ctx do
      assert IntegrationCacheQueries.prune_ended_before(~U[2027-06-01 00:00:00Z]) == 2

      assert map_size(Bookability.for_user(ctx.user.id)) == 2
    end
  end

  defp row_attrs(integration, uid) do
    %{uid: uid, calendar_integration_id: integration.id, provider_event_id: "evt-" <> uid}
    |> event()
    |> ProviderCalendarEventSchema.from_calendar_event()
  end
end
