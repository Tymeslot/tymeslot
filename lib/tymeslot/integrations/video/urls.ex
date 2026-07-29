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
    room_id(room_data)
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

  defp room_id(%{room_id: room_id}) when is_binary(room_id), do: room_id
  defp room_id(_room_data), do: "unknown"
end
