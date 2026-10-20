defmodule TymeslotWeb.Dashboard.Calendar.IcsImportAsyncTest do
  @moduledoc """
  A plan read for a file that was since replaced (even by one of the same
  name) is dropped, matched on the ref of the read that produced it.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Dashboard.Calendar.IcsImport

  defp reading_socket(ref) do
    state = %{
      stage: :reading,
      file_name: "week.ics",
      read_ref: ref,
      plan: nil,
      error: nil,
      summary: nil,
      result: nil
    }

    %Socket{assigns: %{__changed__: %{}, ics_import: state}}
  end

  test "a plan carrying a stale ref is dropped, even for a file of the same name" do
    socket = reading_socket(make_ref())
    stale = make_ref()

    assert {:noreply, ^socket} =
             IcsImport.async(:ics_import_plan, {:ok, {stale, {:error, :invalid_file}}}, socket)
  end

  test "a plan carrying the current ref is taken" do
    ref = make_ref()
    socket = reading_socket(ref)

    assert {:noreply, taken} =
             IcsImport.async(:ics_import_plan, {:ok, {ref, {:error, :invalid_file}}}, socket)

    refute taken.assigns.ics_import.stage == :reading
  end
end
