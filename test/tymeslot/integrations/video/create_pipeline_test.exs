defmodule Tymeslot.Integrations.Video.CreatePipelineTest do
  @moduledoc """
  Connecting any video provider runs the same checks in the same order: a
  duplicate is refused first, then the config is validated, and only then is
  a metered connection test spent.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Video

  setup :verify_on_exit!

  setup do
    %{user: insert(:user)}
  end

  test "refuses a malformed custom link before saving it", %{user: user} do
    assert {:error, "Invalid URL format. Please provide a valid HTTP/HTTPS URL."} =
             Video.create_integration(user.id, :custom, %{
               "name" => "Room",
               "custom_meeting_url" => "not a link"
             })

    assert Video.list_integrations(user.id) == []
  end

  test "connects a well-formed custom link", %{user: user} do
    assert {:ok, _integration} =
             Video.create_integration(user.id, :custom, %{
               "name" => "Room",
               "custom_meeting_url" => "https://meet.example.com/standing-room"
             })
  end

  test "refuses a second kMeet before the database is asked", %{user: user} do
    assert {:ok, _first} = Video.create_integration(user.id, :kmeet, %{"name" => "kMeet"})

    assert {:error, :provider_already_connected} =
             Video.create_integration(user.id, :kmeet, %{"name" => "kMeet again"})
  end

  # The duplicate is decided first, so a repeat is answered as one even when
  # its config would also be refused.
  test "answers a repeated Jitsi server as a duplicate", %{user: user} do
    attrs = %{"name" => "Jitsi", "base_url" => "https://jitsi.example.com"}
    assert {:ok, _first} = Video.create_integration(user.id, :jitsi, attrs)

    assert {:error, _duplicate} =
             Video.create_integration(user.id, :jitsi, Map.put(attrs, "client_id", "half-a-pair"))

    assert length(Video.list_integrations(user.id)) == 1
  end

  # No HTTP expectation is set: a probe would fail the test.
  test "spends no connection test on a repeated MiroTalk server", %{user: user} do
    insert(:video_integration,
      user: user,
      provider: "mirotalk",
      base_url: "https://mirotalk.example.com",
      provider_account_id: "https://mirotalk.example.com"
    )

    assert {:error, _duplicate} =
             Video.create_integration(user.id, :mirotalk, %{
               "name" => "MiroTalk",
               "api_key" => "key",
               "base_url" => "https://mirotalk.example.com"
             })
  end

  # The API key travels with every request, and a login name or password in
  # the address would travel beside it as Basic auth. No HTTP expectation: the
  # refusal spends no connection test.
  test "refuses a MiroTalk address with a login name, a query or a fragment", %{user: user} do
    for url <- [
          "https://admin:secret@mirotalk.example.com",
          "https://mirotalk.example.com/?x=1",
          "https://mirotalk.example.com/#top"
        ] do
      assert {:error, message} =
               Video.create_integration(user.id, :mirotalk, %{
                 "name" => "MiroTalk",
                 "api_key" => "key",
                 "base_url" => url
               })

      assert message =~ "The server URL cannot contain"
    end

    assert Video.list_integrations(user.id) == []
  end

  test "refuses an edit moving MiroTalk onto such an address", %{user: user} do
    integration =
      insert(:video_integration,
        user: user,
        provider: "mirotalk",
        base_url: "https://mirotalk.example.com",
        provider_account_id: "https://mirotalk.example.com"
      )

    assert {:error, message} =
             Video.update_integration(user.id, integration.id, %{
               "base_url" => "https://admin:secret@mirotalk.example.com"
             })

    assert message =~ "cannot contain a login name or password"
    assert Repo.reload!(integration).base_url == "https://mirotalk.example.com"
  end

  # The address was saved before the rule; only a new one is checked.
  test "keeps a MiroTalk address stored before the rule through a rename", %{user: user} do
    integration =
      insert(:video_integration,
        user: user,
        provider: "mirotalk",
        base_url: "https://mirotalk.example.com/?team=1",
        provider_account_id: "https://mirotalk.example.com/?team=1"
      )

    assert {:ok, %{name: "Team room"}} =
             Video.update_integration(user.id, integration.id, %{
               "name" => "Team room",
               "base_url" => "https://mirotalk.example.com/?team=1"
             })
  end
end
