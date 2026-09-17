defmodule TymeslotWeb.Dashboard.CalendarEventHandlersVideoTest do
  @moduledoc """
  What the calendar grid tells the organiser when a video provider refuses to
  make a room for one of its events.

  A refusal caused by a setting on the organiser's own server says which
  setting, in the same words their video integration's row uses; anything else
  is a failure they can only try again.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :video

  alias Phoenix.Flash
  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Dashboard.CalendarEventHandlers

  describe "handle_video_sync_result/3 on a failure" do
    test "says which Talk setting refuses the room, and how to change it" do
      assert flash_for({:error, {:configuration_error, :password_required}}) =~
               "turn off the password requirement for public conversations"
    end

    test "says which Talk setting a restricted server refuses with" do
      assert flash_for({:error, {:configuration_error, :conversation_creation_restricted}}) =~
               "allow the user's group to create conversations"
    end

    test "falls back to the general failure for anything else" do
      for reason <- [
            {:error, :timeout},
            {:error, {:configuration_error, :something_no_code_covers}},
            {:error, {:http_error, 502}}
          ] do
        assert flash_for(reason) == "Failed to provision video room - link not updated"
      end
    end
  end

  defp flash_for(result) do
    socket = %Socket{assigns: %{flash: %{}, __changed__: %{}}}

    assert {:noreply, updated} = CalendarEventHandlers.handle_video_sync_result(1, result, socket)

    Flash.get(updated.assigns.flash, :error)
  end
end
