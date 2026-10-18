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

  describe "busy_for_bookings?/3" do
    test "a free all-day event on a read-only calendar is busy" do
      assert Bookability.busy_for_bookings?(event(%{}), true, %{})
    end

    test "the same event on a writable calendar is free" do
      refute Bookability.busy_for_bookings?(event(%{}), false, %{})
    end

    test "a free timed event on a read-only calendar is free" do
      timed =
        event(%{
          all_day: false,
          start_date: nil,
          end_date: nil,
          start_at: ~U[2026-12-25 10:00:00Z],
          end_at: ~U[2026-12-25 11:00:00Z]
        })

      refute Bookability.busy_for_bookings?(timed, true, %{})
    end

    test "a cancelled all-day event on a read-only calendar is free" do
      refute Bookability.busy_for_bookings?(event(%{status: :cancelled}), true, %{})
    end

    test "an override wins either way" do
      holiday = event(%{})
      busy = event(%{transparency: :opaque})

      refute Bookability.busy_for_bookings?(holiday, true, %{{1, "event-1"} => false})
      assert Bookability.busy_for_bookings?(holiday, false, %{{1, "event-1"} => true})
      refute Bookability.busy_for_bookings?(busy, false, %{{1, "event-1"} => false})
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

  describe "read_only?/2" do
    test "a subscribed feed and a calendar the provider marks read-only are read-only" do
      feed = insert(:calendar_integration, provider: "ics_url")

      google =
        insert(:calendar_integration,
          provider: "google",
          calendar_list: [
            %{"id" => "holidays", "selected" => true, "read_only" => true},
            %{"id" => "work", "selected" => true}
          ]
        )

      assert Bookability.read_only?(event(%{calendar_integration_id: feed.id}), feed)
      assert Bookability.read_only?(event(%{calendar_integration_id: google.id}), google)

      refute Bookability.read_only?(
               event(%{calendar_integration_id: google.id, provider_calendar_id: "work"}),
               google
             )
    end
  end
end
