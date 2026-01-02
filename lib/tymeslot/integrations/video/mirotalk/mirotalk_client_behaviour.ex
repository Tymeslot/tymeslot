defmodule Tymeslot.Integrations.Video.MiroTalk.MiroTalkClientBehaviour do
  @moduledoc """
  Behavior for MiroTalk provider operations to enable mocking in tests.
  """

  @callback create_meeting_room(map()) :: {:ok, map()} | {:error, any()}
  @callback extract_room_id(String.t()) :: String.t() | nil
  @callback create_direct_join_url(String.t(), String.t()) :: String.t()
  @callback create_secure_direct_join_url(String.t(), String.t(), String.t(), DateTime.t()) ::
              String.t()
  @callback valid_meeting_url?(String.t()) :: boolean()
  @callback test_connection(map()) :: {:ok, String.t()} | {:error, any()}
end
