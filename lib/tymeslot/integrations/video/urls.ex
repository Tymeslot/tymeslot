defmodule Tymeslot.Integrations.Video.Urls do
  @moduledoc """
  URL helpers for video integrations.

  Provides functions to extract room IDs from meeting contexts and meeting
  URLs.
  """

  alias Tymeslot.Integrations.Video.MeetingContext
  alias Tymeslot.Integrations.Video.Providers.ProviderAdapter

  @doc """
  Reads the room id out of a meeting context.
  """
  @spec extract_room_id(MeetingContext.t()) :: String.t() | nil
  def extract_room_id(%{room_data: room_data}) when is_map(room_data) do
    # No placeholder fallback here: a context without a room id has no room, and
    # returning a stand-in string would let callers persist an unusable room.
    Map.get(room_data, :room_id)
  end

  def extract_room_id(_other), do: nil

  @doc """
  Extracts the room id from a meeting URL using `provider`'s own rules.

  For every caller that already knows which provider issued the link: the
  integration record naming it, or a code path that can only run for one
  provider. Accepts the atom or the string form.
  """
  @spec extract_room_id(String.t(), atom() | String.t()) :: String.t() | nil
  def extract_room_id(meeting_url, provider) when is_binary(meeting_url) do
    ProviderAdapter.extract_room_id(meeting_url, provider)
  end

  def extract_room_id(_other, _provider), do: nil
end
