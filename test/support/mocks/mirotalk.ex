defmodule Tymeslot.Mocks.MiroTalk do
  @moduledoc """
  MiroTalk video provider mocks.

  See `Tymeslot.TestMocks` for the public API (`setup_mirotalk_mocks/1`).
  """

  import Mox

  @spec setup(keyword()) :: term()
  def setup(opts \\ []) do
    room_url = Keyword.get(opts, :room_url, "https://test.mirotalk.com/join/test-room-123")
    create_result = Keyword.get(opts, :create_result, {:ok, room_url})

    Tymeslot.MiroTalkAPIMock
    |> stub(:create_meeting_room, fn _config -> create_result end)
    |> stub(:extract_room_id, fn url ->
      case String.contains?(url, "/join/") do
        true -> url |> String.split("/join/") |> List.last()
        false -> nil
      end
    end)
    |> stub(:create_direct_join_url, fn room_id, participant_name ->
      "#{room_url}?name=#{URI.encode(participant_name)}&room_id=#{room_id}"
    end)
    |> stub(:create_secure_direct_join_url, fn _room_id, name, role, _datetime ->
      case role do
        "organizer" -> "#{room_url}?role=organizer&token=org123"
        "attendee" -> "#{room_url}?role=attendee&token=att456"
        _other -> "#{room_url}?name=#{URI.encode(name)}&role=#{role}"
      end
    end)
  end
end
