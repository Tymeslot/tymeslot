defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceBlockTest do
  @moduledoc """
  "Block this time" from the bookable layer's explainer: the window it
  blocks leaves the layer, the toast names it, Undo brings it back, and a
  block that cannot be made is refused with a reason.

  The organiser has no calendar connected here, so the block is the part-day
  time off `Changes.block_time/4` writes without a writable calendar.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import TymeslotWeb.BookableLayerHelpers
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Phoenix.LiveView.Socket
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Dashboard.Calendar.BlockTime
  alias TymeslotWeb.Dashboard.Calendar.UndoStack

  @thursday %{"start" => "2026-10-15T09:00", "end" => "2026-10-15T17:00"}

  setup %{conn: conn} do
    context = owner(conn)
    Repo.delete!(context.integration)
    open_days(context.user)
    meeting_type(context.user)
    context
  end

  defp loaded(conn) do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    await_bookable(lv, &on_day?(&1, "2026-10-15"))
    lv
  end

  defp block(lv, params),
    do: lv |> element("#calendar-canvas") |> render_hook("calendar:block", params)

  test "blocking a window takes it off the layer, and undo puts it back", %{conn: conn} do
    lv = loaded(conn)

    block(lv, @thursday)
    assert_reply(lv, %{accepted: true})

    layer = await_bookable(lv, &(on_day?(&1, "2026-10-16") and not on_day?(&1, "2026-10-15")))
    refute on_day?(layer, "2026-10-15")

    assert has_element?(
             lv,
             "#calendar-toast",
             "Blocked Thu 15 Oct, 09:00 to 17:00. Guests can't book this time."
           )

    lv |> element("#calendar-undo") |> render_click()

    layer = await_bookable(lv, &on_day?(&1, "2026-10-15"))
    assert %{start: "2026-10-15T09:00", end: "2026-10-15T17:00"} in layer.windows
    assert has_element?(lv, "#calendar-toast", "Unblocked. Guests can book this time again.")
  end

  test "Ctrl Z undoes a block as well", %{conn: conn} do
    lv = loaded(conn)

    block(lv, @thursday)
    assert_reply(lv, %{accepted: true})
    await_bookable(lv, &(on_day?(&1, "2026-10-16") and not on_day?(&1, "2026-10-15")))

    lv |> element("#calendar-canvas") |> render_hook("calendar:undo", %{})

    assert await_bookable(lv, &on_day?(&1, "2026-10-15"))
  end

  test "a span that ends before it starts is refused", %{conn: conn} do
    lv = loaded(conn)

    block(lv, %{"start" => "2026-10-15T17:00", "end" => "2026-10-15T09:00"})

    assert_reply(lv, %{accepted: false, error: "That time can't be blocked."})
  end

  test "a time already over is refused and says so", %{conn: conn} do
    lv = loaded(conn)

    block(lv, %{"start" => "2026-10-13T09:00", "end" => "2026-10-13T10:00"})

    assert_reply(lv, %{accepted: false, error: "That time has already passed."})
  end

  test "a span past the block's own limit of a week is refused and names it", %{conn: conn} do
    lv = loaded(conn)

    block(lv, %{"start" => "2026-10-15T09:00", "end" => "2026-10-22T09:01"})

    assert_reply(lv, %{accepted: false, error: "You can block at most a week at a time."})
  end

  test "a span longer than a day but within the week is accepted", %{conn: conn} do
    lv = loaded(conn)

    block(lv, %{"start" => "2026-10-15T09:00", "end" => "2026-10-16T09:01"})

    assert_reply(lv, %{accepted: true})
  end

  test "text that is not a time is refused", %{conn: conn} do
    lv = loaded(conn)

    block(lv, %{"start" => "soon", "end" => "later"})
    assert_reply(lv, %{accepted: false, error: "That time can't be blocked."})

    block(lv, %{"start" => "2026-10-15T09:00"})
    assert_reply(lv, %{accepted: false, error: "That time can't be blocked."})
  end

  test "a block past the edit rate limit is refused with the limiter's message", %{
    conn: conn,
    user: user
  } do
    lv = loaded(conn)

    {:error, :rate_limited, message} =
      Enum.find(
        Stream.repeatedly(fn -> RateLimiter.check(:calendar_event_edit, user.id) end),
        &match?({:error, :rate_limited, _message}, &1)
      )

    block(lv, @thursday)

    assert_reply(lv, %{accepted: false, error: ^message})
  end

  describe "answers the layer's block can get from an unreachable calendar" do
    defp bare_socket,
      do: %Socket{
        assigns: %{
          __changed__: %{},
          id: "calendar-surface",
          undo: UndoStack.new(),
          timezone: "Europe/London",
          time_format: "24h",
          toast: nil,
          flash: %{}
        }
      }

    test "a queued block says so, with no Undo and nothing on the stack" do
      at = ~U[2026-10-15 08:00:00Z]

      socket =
        BlockTime.blocked(
          bare_socket(),
          {:block, 1},
          {:ok, {at, at, {:error, {:queued, :timeout}}}}
        )

      assert socket.assigns.toast.message ==
               "Saved. It will block this time once your calendar is reachable again."

      refute socket.assigns.toast.undo
      assert socket.assigns.undo == bare_socket().assigns.undo
    end

    test "a queued undo says so and does not put the block back on the stack" do
      socket = BlockTime.unblocked(bare_socket(), {:ok, {%{}, {:error, {:queued, :timeout}}}})

      assert socket.assigns.toast.message ==
               "Saved. The time will free up once your calendar is reachable again."

      assert socket.assigns.undo == bare_socket().assigns.undo
    end

    test "too far ahead and too many time-off periods have their own flashes" do
      at = ~U[2026-10-15 08:00:00Z]

      for {reason, text} <- [
            too_far: "That's too far ahead to block.",
            limit_reached:
              "You have too many time-off periods to block more time. Remove some first."
          ] do
        BlockTime.blocked(bare_socket(), {:block, 1}, {:ok, {at, at, {:error, reason}}})
        assert_received {:flash, {:error, ^text}}
      end
    end

    test "a failed undo goes back on top of the stack with the error flash" do
      entry = %{kind: :block, key: {:block, 1}, id: nil, result: :r}
      socket = BlockTime.unblocked(bare_socket(), {:ok, {entry, {:error, :boom}}})

      assert [^entry | _rest] = socket.assigns.undo
      assert_received {:flash, {:error, "Couldn't undo the block. Please try again."}}
    end

    test "an undo of a block that is already gone leaves the stack and says so" do
      entry = %{kind: :block, key: {:block, 1}, id: nil, result: :r}
      socket = BlockTime.unblocked(bare_socket(), {:ok, {entry, {:error, :not_found}}})

      assert socket.assigns.undo == bare_socket().assigns.undo
      assert socket.assigns.toast.message == "That change can't be undone any more."
    end

    test "an undo of a block moved or renamed since leaves the stack and says so" do
      entry = %{kind: :block, key: {:block, 1}, id: nil, result: :r}
      socket = BlockTime.unblocked(bare_socket(), {:ok, {entry, {:error, :changed}}})

      assert socket.assigns.undo == bare_socket().assigns.undo

      assert socket.assigns.toast.message ==
               "Couldn't undo the block. It has been moved or renamed since."
    end
  end
end
