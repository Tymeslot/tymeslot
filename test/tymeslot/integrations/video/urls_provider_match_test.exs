defmodule Tymeslot.Integrations.Video.UrlsProviderMatchTest do
  @moduledoc """
  A meeting link yields a room id for one integration only when it is that
  integration's provider's link.
  """

  use ExUnit.Case, async: true

  @moduletag :video

  alias Tymeslot.Integrations.Video.Urls

  @talk_link "https://cloud.example.org/call/abc123"

  test "returns the room id for a link of the given provider" do
    assert Urls.extract_room_id(@talk_link, "nextcloud_talk") == "abc123"
  end

  test "returns nil for another provider's link" do
    # A Nextcloud Talk link on an event whose integration is Zoom has no Zoom
    # room behind it.
    assert Urls.extract_room_id(@talk_link, "zoom") == nil
  end

  test "returns nil for an unknown provider or a link nobody recognises" do
    assert Urls.extract_room_id(@talk_link, "no-such-provider") == nil
    assert Urls.extract_room_id("https://example.org/somewhere", "nextcloud_talk") == nil
    assert Urls.extract_room_id(nil, "zoom") == nil
  end
end
