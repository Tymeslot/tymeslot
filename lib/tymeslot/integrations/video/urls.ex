defmodule Tymeslot.Integrations.Video.Urls do
  @moduledoc """
  URL helpers for video integrations.

  Provides functions to extract room IDs and validate meeting URLs.
  Accepts either raw URLs or meeting context maps.
  """

  alias Tymeslot.Integrations.Video.MeetingContext
  alias Tymeslot.Integrations.Video.Providers.ProviderAdapter

  @spec extract_room_id(String.t() | MeetingContext.t()) :: String.t() | nil
  def extract_room_id(%{room_data: room_data}) when is_map(room_data) do
    # No placeholder fallback here: a context without a room id has no room, and
    # returning a stand-in string would let callers persist an unusable room.
    Map.get(room_data, :room_id)
  end

  def extract_room_id(meeting_url) when is_binary(meeting_url) do
    ProviderAdapter.extract_room_id(meeting_url)
  end

  def extract_room_id(_other), do: nil

  @spec valid_meeting_url?(String.t()) :: boolean()
  def valid_meeting_url?(meeting_url) when is_binary(meeting_url) do
    ProviderAdapter.valid_meeting_url?(meeting_url)
  end

  def valid_meeting_url?(_url), do: false
end
