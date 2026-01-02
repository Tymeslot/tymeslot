defmodule Tymeslot.Integrations.Video.Urls do
  @moduledoc """
  URL helpers for video integrations.

  Provides functions to extract room IDs and validate meeting URLs.
  Accepts either raw URLs or meeting context maps.
  """

  alias Tymeslot.Integrations.Video.Providers.ProviderAdapter

  @spec extract_room_id(String.t() | map()) :: String.t() | nil
  def extract_room_id(%{room_data: room_data}) when is_map(room_data) do
    room_data[:room_id] || room_data["room_id"] || "unknown"
  end

  def extract_room_id(meeting_url) when is_binary(meeting_url) do
    ProviderAdapter.extract_room_id(meeting_url)
  end

  def extract_room_id(_), do: nil

  @spec valid_meeting_url?(String.t()) :: boolean()
  def valid_meeting_url?(meeting_url) when is_binary(meeting_url) do
    ProviderAdapter.valid_meeting_url?(meeting_url)
  end

  def valid_meeting_url?(_), do: false
end
