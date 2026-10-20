defmodule Tymeslot.CalendarGrid.EditGuardTest do
  @moduledoc """
  Whether an event may be changed from the calendar: the organiser's own
  integration, a calendar that takes writes, and not a Tymeslot booking.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar

  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.EditGuard
  alias Tymeslot.Security.RateLimiter

  setup do
    user = insert(:user)

    insert(:calendar_integration,
      user: user,
      provider: "google",
      is_active: true,
      calendar_list: [
        %{"id" => "work", "name" => "Work", "selected" => true},
        %{"id" => "shared", "name" => "Shared", "selected" => true, "read_only" => true}
      ]
    )

    # Loaded as the calendars load it, with the calendar list cast to entries.
    [integration] = CalendarGrid.list_active_integrations(user.id)
    %{user: user, integration: integration}
  end

  defp event(integration, calendar_id),
    do: %{uid: "u1", calendar_integration_id: integration.id, provider_calendar_id: calendar_id}

  test "an event on the organiser's writable calendar may be changed", %{integration: integration} do
    assert EditGuard.writable([integration], event(integration, "work")) == :ok
    assert EditGuard.editable?([integration], event(integration, "work"))
  end

  test "an event on a read-only calendar may not", %{integration: integration} do
    assert EditGuard.writable([integration], event(integration, "shared")) == {:error, :read_only}
    refute EditGuard.editable?([integration], event(integration, "shared"))
  end

  test "an event on someone else's integration may not", %{integration: integration} do
    other = insert(:calendar_integration, provider: "google")

    assert EditGuard.writable([integration], event(other, "work")) == {:error, :unauthorized}
  end

  test "a Tymeslot booking is changed from the booking, not here", %{integration: integration} do
    assert EditGuard.writable([integration], %{kind: :booking, id: "b1"}) == {:error, :booking}
  end

  test "check/3 passes a writable, unbooked event within the rate limit", %{
    user: user,
    integration: integration
  } do
    assert EditGuard.check(user.id, [integration], event(integration, "work")) == :ok
  end

  test "check/3 refuses an event a group meeting with live seats sits on", %{
    user: user,
    integration: integration
  } do
    meeting =
      insert(:meeting,
        organizer_user: user,
        organizer_email: user.email,
        capacity: 4,
        calendar_uid: "group-uid-1"
      )

    insert(:participant, meeting: meeting)

    event = %{event(integration, "work") | uid: "group-uid-1"}

    assert EditGuard.check(user.id, [integration], event) == {:error, :group_booking}
  end

  test "seat_lock/2 refuses a group meeting's copy only while seats are live", %{
    user: user,
    integration: integration
  } do
    meeting =
      insert(:meeting,
        organizer_user: user,
        organizer_email: user.email,
        capacity: 4,
        calendar_uid: "group-uid-2"
      )

    event = %{event(integration, "work") | uid: "group-uid-2"}

    assert EditGuard.seat_lock(user.id, event) == :ok

    insert(:participant, meeting: meeting)

    assert EditGuard.seat_lock(user.id, event) == {:error, :group_booking}
  end

  test "check/3 refuses once the organiser is past the edit rate limit", %{
    user: user,
    integration: integration
  } do
    for _attempt <- 1..30, do: RateLimiter.check(:calendar_event_edit, user.id)

    assert {:error, :rate_limited, message} =
             EditGuard.check(user.id, [integration], event(integration, "work"))

    assert message =~ "calendar event edit"
  end

  describe "the calendar copy of a booking" do
    setup %{user: user, integration: integration} do
      insert(:meeting,
        organizer_user: user,
        calendar_integration_id: integration.id,
        calendar_uid: "copy-uid"
      )

      %{copy: %{event(integration, "work") | uid: "copy-uid"}}
    end

    test "can be changed in general but not moved", %{
      user: user,
      integration: integration,
      copy: copy
    } do
      assert EditGuard.editable?([integration], copy)
      refute EditGuard.movable?([integration], copy)
      assert EditGuard.check(user.id, [integration], copy) == :ok
      assert EditGuard.check_timing(user.id, [integration], copy) == {:error, :booking}
    end

    test "an ordinary event on the same calendar can be moved", %{
      user: user,
      integration: integration
    } do
      assert EditGuard.movable?([integration], event(integration, "work"))
      assert EditGuard.check_timing(user.id, [integration], event(integration, "work")) == :ok
    end
  end

  describe "check_transfer/3" do
    test "lets an event on a writable calendar move", %{user: user, integration: integration} do
      assert EditGuard.check_transfer(user.id, [integration], event(integration, "work")) == :ok
    end

    test "refuses an event on a read-only calendar", %{user: user, integration: integration} do
      assert EditGuard.check_transfer(user.id, [integration], event(integration, "shared")) ==
               {:error, :read_only}
    end

    test "refuses the calendar copy of a booking", %{user: user, integration: integration} do
      copy = %{event(integration, "work") | uid: "booked-copy"}

      insert(:meeting,
        organizer_user: user,
        calendar_integration_id: integration.id,
        calendar_uid: "booked-copy"
      )

      assert EditGuard.check_transfer(user.id, [integration], copy) == {:error, :booking}
    end

    test "transfer_gates/3 does not count a move", %{user: user, integration: integration} do
      for _attempt <- 1..5,
          do:
            assert(
              EditGuard.transfer_gates(user.id, [integration], event(integration, "work")) == :ok
            )

      assert EditGuard.check_transfer(user.id, [integration], event(integration, "work")) == :ok
    end

    test "counts against the move rate limit", %{user: user, integration: integration} do
      # Three moves a minute (`RateLimiter.Limits`, `:calendar_event_move`).
      for _attempt <- 1..3, do: RateLimiter.check(:calendar_event_move, user.id)

      assert {:error, :rate_limited, _message} =
               EditGuard.check_transfer(user.id, [integration], event(integration, "work"))
    end
  end

  describe "free_busy_editable?/2" do
    test "an event on a writable calendar may change its Busy/Free", %{integration: integration} do
      assert EditGuard.free_busy_editable?([integration], event(integration, "work"))
    end

    test "a booking and an event on a read-only calendar may not", %{integration: integration} do
      refute EditGuard.free_busy_editable?([integration], %{kind: :booking, id: "booking-1"})
      refute EditGuard.free_busy_editable?([integration], event(integration, "shared"))
    end

    test "nor may the calendar copy of a booking, which follows its meeting type", %{
      user: user,
      integration: integration
    } do
      copy = %{event(integration, "work") | uid: "booked-copy"}

      insert(:meeting,
        organizer_user: user,
        calendar_integration_id: integration.id,
        calendar_uid: "booked-copy"
      )

      refute EditGuard.free_busy_editable?([integration], copy)
    end
  end

  describe "free_busy_change/1" do
    test "lets an ordinary event change its Busy/Free", %{integration: integration} do
      assert EditGuard.free_busy_change(event(integration, "work")) == :ok
    end

    test "refuses a booking",
      do: assert(EditGuard.free_busy_change(%{kind: :booking}) == {:error, :booking})

    test "refuses the calendar copy of a booking", %{user: user, integration: integration} do
      insert(:meeting,
        organizer_user: user,
        calendar_integration_id: integration.id,
        calendar_uid: "free-busy-copy"
      )

      assert EditGuard.free_busy_change(%{event(integration, "work") | uid: "free-busy-copy"}) ==
               {:error, :booking}
    end
  end

  describe "guest_update/3" do
    test "lets the organiser tell the guests of an event on a writable calendar", %{
      user: user,
      integration: integration
    } do
      assert EditGuard.guest_update(user.id, [integration], event(integration, "work")) == :ok
    end

    test "refuses an event someone else organises", %{user: user, integration: integration} do
      event =
        Map.put(event(integration, "work"), :organiser, %{"email" => "boss@elsewhere.example"})

      assert EditGuard.guest_update(user.id, [integration], event) == {:error, :not_organiser}
    end

    test "refuses an event on a read-only calendar", %{user: user, integration: integration} do
      assert EditGuard.guest_update(user.id, [integration], event(integration, "shared")) ==
               {:error, :read_only}
    end
  end
end
