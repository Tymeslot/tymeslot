defmodule TymeslotWeb.Dashboard.Calendar.BookingPreviewTest do
  @moduledoc """
  What a booking's preview offers at a given moment. The `expired` flag is
  decided when the window loads, so a request left on screen past its start
  or its approval deadline must still read as expired once the preview opens.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :bookings

  alias TymeslotWeb.Dashboard.Calendar.BookingPreview

  @now ~U[2026-10-14 08:00:00Z]
  @expired {:note, "This request expired without an answer"}

  defp request(attrs) do
    Map.merge(
      %{
        kind: :booking,
        request: true,
        expired: false,
        start_at: ~U[2026-10-15 10:00:00Z],
        end_at: ~U[2026-10-15 10:30:00Z],
        approval_deadline_at: ~U[2026-10-15 08:00:00Z]
      },
      attrs
    )
  end

  test "a request still open can be answered" do
    assert BookingPreview.state(request(%{}), @now) == :answer
  end

  test "a request whose approval deadline has passed since it loaded is expired" do
    assert BookingPreview.state(request(%{approval_deadline_at: ~U[2026-10-14 08:00:00Z]}), @now) ==
             @expired
  end

  test "a request whose start has passed since it loaded is expired" do
    request =
      request(%{
        start_at: ~U[2026-10-14 07:59:00Z],
        end_at: ~U[2026-10-14 08:29:00Z],
        approval_deadline_at: nil
      })

    assert BookingPreview.state(request, @now) == @expired
  end
end
