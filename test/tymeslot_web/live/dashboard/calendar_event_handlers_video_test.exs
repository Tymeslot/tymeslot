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

  describe "handle_event_video_result/2 on a change" do
    test "confirms a room was created" do
      assert info_for(change(1, "https://v.ex/x")) == "Video room created."
    end

    test "confirms the link was removed" do
      assert info_for(change(nil, nil)) == "Video link removed."
    end
  end

  describe "handle_event_video_result/2 on a failure" do
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
               "The video provider did not return a meeting link, so the video link was not changed."
    end

    test "falls back to the general failure for anything else" do
      for reason <- [
            :timeout,
            {:configuration_error, :something_no_code_covers},
            {:http_error, 502}
          ] do
        assert flash_for(failure(reason)) ==
                 "Could not change the video link - changes reverted"
      end
    end
  end

  # A successful change carries both events, so the grid can diff them for the
  # attendee-notification prompt; the wording follows the updated link alone.
  defp change(video_integration_id, video_link) do
    {:ok,
     original_event: %{id: 1, video_integration_id: nil, video_link: nil},
     updated_event: %{id: 1, video_integration_id: video_integration_id, video_link: video_link}}
  end

  # A refusal carries the event as it was, so the grid can put the previous
  # choice back; only the reason decides the wording.
  defp failure(reason),
    do: {:error, [original_event: %{id: 1, video_integration_id: nil}, reason: reason]}

  defp flash_for(result), do: result |> apply_result() |> Flash.get(:error)

  defp info_for(result), do: result |> apply_result() |> Flash.get(:info)

  defp apply_result(result) do
    socket = %Socket{assigns: %{flash: %{}, __changed__: %{}, live_action: :dashboard}}

    assert {:noreply, updated} = CalendarEventHandlers.handle_event_video_result(result, socket)

    updated.assigns.flash
  end
end
