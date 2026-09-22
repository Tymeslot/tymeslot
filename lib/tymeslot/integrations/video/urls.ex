defmodule Tymeslot.Integrations.Video.Urls do
  @moduledoc """
  URL helpers for video integrations.

  Provides functions to extract room IDs and validate meeting URLs.
  Accepts either raw URLs or meeting context maps.
  """

  alias Tymeslot.Integrations.Video.MeetingContext
  alias Tymeslot.Integrations.Video.Providers.ProviderAdapter

  @doc """
  Reads the room id out of a meeting context, or guesses it from a bare URL.

  A context carries the id outright. A URL does not, so the provider is
  inferred from the link's shape, which is a **best-effort guess**: providers
  whose URLs share a substring resolve to whichever is listed first, and the id
  then comes back parsed by the wrong provider's rules. It is meant for callers
  that have nothing but a link, such as naming the service behind a URL a user
  has just pasted. **A caller holding an integration must not use it** and
  should call `extract_room_id/2` with the provider it already knows.
  """
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

  @spec valid_meeting_url?(String.t()) :: boolean()
  def valid_meeting_url?(meeting_url) when is_binary(meeting_url) do
    ProviderAdapter.valid_meeting_url?(meeting_url)
  end

  def valid_meeting_url?(_url), do: false
end
