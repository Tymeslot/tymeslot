defmodule TymeslotWeb.Dashboard.Calendar.PanelStatusTest do
  @moduledoc """
  The side panel's header line follows its own writes: saving while any
  runs, saved when they have all answered, waiting when the calendar could
  not be reached, failed when a write was put back.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :unit

  alias TymeslotWeb.Dashboard.Calendar.PanelStatus

  @panel %{status: :idle, writes: []}

  test "a write saves, then says saved once it has answered" do
    panel = PanelStatus.started(@panel, :one)
    assert panel.status == :saving

    assert PanelStatus.settled(panel, :one, {:ok, %{}}, "Work account").status == :saved
  end

  test "stays saving while another of its writes is running" do
    panel = @panel |> PanelStatus.started(:one) |> PanelStatus.started(:two)

    assert PanelStatus.settled(panel, :one, :unchanged, "Work account").status == :saving
  end

  test "a queued write says where it is waiting to go" do
    panel = @panel |> PanelStatus.started(:one) |> PanelStatus.settled(:one, :queued, "Work")

    assert PanelStatus.text(panel.status) == "Saved here, waiting to reach Work"
  end

  test "a failed write says it was put back" do
    panel = @panel |> PanelStatus.started(:one) |> PanelStatus.settled(:one, :failed, "Work")

    assert PanelStatus.text(panel.status) == "Couldn't save. The change was put back."
  end

  test "an answer to a write it did not start changes nothing" do
    panel = PanelStatus.started(@panel, :one)

    assert PanelStatus.settled(panel, :other, :failed, "Work") == panel
  end

  test "a refusal says why" do
    panel = PanelStatus.refused(@panel, "Too many edits. Please wait a moment.")

    assert PanelStatus.text(panel.status) ==
             "Couldn't save. Too many edits. Please wait a moment."
  end

  test "the idle and read-only lines" do
    assert PanelStatus.text(:idle) == "Changes save automatically"
    assert PanelStatus.text(:read_only) == "Read only"
  end
end
