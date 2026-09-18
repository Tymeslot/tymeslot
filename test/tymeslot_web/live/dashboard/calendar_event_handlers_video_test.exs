defmodule TymeslotWeb.Dashboard.CalendarEventHandlersVideoTest do
  @moduledoc """
  What the calendar grid tells the organiser after they pick or clear a video
  provider for one of its events.

  A change is confirmed in the words of what happened. A refusal caused by a
  setting on the organiser's own server says which setting, in the same words
  their video integration's row uses; anything else is a failure they can only
  try again.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :video

  alias Phoenix.Flash
  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Dashboard.CalendarEventHandlers

  describe "handle_video_sync_result/3 on a change" do
    test "confirms a room was created" do
      assert info_for({:ok, %{video_integration_id: 1, video_link: "https://v.example/x"}}) ==
               "Video room created."
    end

    test "confirms the link was removed" do
      assert info_for({:ok, %{video_integration_id: nil, video_link: nil}}) ==
               "Video link removed."
    end
  end

  describe "handle_video_sync_result/3 on a failure" do
    test "says which Talk setting refuses the room, and how to change it" do
      assert flash_for(failure({:configuration_error, :password_required})) =~
               "turn off the password requirement for public conversations"
    end

    test "says which Talk setting a restricted server refuses with" do
      assert flash_for(failure({:configuration_error, :conversation_creation_restricted})) =~
               "allow the user's group to create conversations"
    end

    test "says the provider gave no link when that is what happened" do
      assert flash_for(failure(:missing_meeting_url)) ==
               "The video provider gave no meeting link, so the video link was not changed."
    end

    test "falls back to the general failure for anything else" do
      for reason <- [
            :timeout,
            {:configuration_error, :something_no_code_covers},
            {:http_error, 502}
          ] do
        assert flash_for(failure(reason)) ==
                 "Failed to provision video room - link not updated"
      end
    end
  end

  # A refusal carries the choice the event still has, so the picker can go
  # back to it; only the reason decides the wording.
  defp failure(reason),
    do: {:error, %{reason: reason, video_integration_id: nil, video_link: nil}}

  defp flash_for(result), do: result |> apply_result() |> Flash.get(:error)

  defp info_for(result), do: result |> apply_result() |> Flash.get(:info)

  defp apply_result(result) do
    socket = %Socket{assigns: %{flash: %{}, __changed__: %{}, live_action: :dashboard}}

    assert {:noreply, updated} = CalendarEventHandlers.handle_video_sync_result(1, result, socket)

    updated.assigns.flash
  end
end
