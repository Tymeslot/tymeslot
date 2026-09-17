defmodule Tymeslot.Integrations.Video.Providers.JitsiProviderTest do
  use ExUnit.Case, async: true

  @moduletag :integrations

  import Mox

  alias Joken.Signer
  alias Tymeslot.Integrations.Video.Providers.JitsiProvider
  alias Tymeslot.Integrations.Video.RoomData
  alias Tymeslot.Test.LogCapture

  setup :verify_on_exit!

  @base_url "https://meet.example.com"
  @app_id "tymeslot"
  @secret "test-secret-value-at-least-32-chars-long"
  @grace_seconds 4 * 60 * 60

  describe "identity" do
    test "declares its provider type, name and bucket" do
      assert JitsiProvider.provider_type() == :jitsi
      assert JitsiProvider.display_name() == "Jitsi Meet"
      assert JitsiProvider.connection_test_bucket() == :jitsi
    end
  end

  describe "create_meeting_room/1" do
    test "appends a generated slug to the configured server" do
      assert {:ok, %RoomData{} = room} =
               JitsiProvider.create_meeting_room(%{base_url: @base_url, meeting_id: "m-1"})

      assert room.meeting_url == @base_url <> "/" <> room.room_id
      assert room.meeting_url =~ ~r/\Ahttps:\/\/meet\.example\.com\/[0-9a-f]{16}\z/
    end

    test "refuses a missing server URL" do
      assert JitsiProvider.create_meeting_room(%{meeting_id: "m-1"}) ==
               {:error, "Base URL is required"}
    end

    test "refuses a non-HTTP server URL" do
      assert JitsiProvider.create_meeting_room(%{base_url: "ftp://x.example", meeting_id: "m-1"}) ==
               {:error, "Invalid URL format. Please provide a valid HTTP/HTTPS URL."}
    end

    test "keeps a plain sub-path on the configured server" do
      assert {:ok, room} =
               JitsiProvider.create_meeting_room(%{
                 base_url: "https://example.com/jitsi",
                 meeting_id: "m-1"
               })

      assert room.meeting_url == "https://example.com/jitsi/" <> room.room_id
      assert JitsiProvider.extract_room_id(room.meeting_url) == room.room_id
    end

    test "refuses a server URL with a query string or a fragment" do
      assert {:error, query_message} =
               JitsiProvider.create_meeting_room(%{
                 base_url: "https://m.example.com/?x=1",
                 meeting_id: "m-1"
               })

      assert query_message =~ "query string"

      assert {:error, fragment_message} =
               JitsiProvider.create_meeting_room(%{
                 base_url: "https://m.example.com/#room",
                 meeting_id: "m-1"
               })

      assert fragment_message =~ "fragment"
    end

    test "refuses a missing meeting id rather than inventing a shared room" do
      assert JitsiProvider.create_meeting_room(%{base_url: @base_url}) ==
               {:error, "A meeting ID is required to create a video room"}
    end

    test "keeps the credentials out of the provider data and the metadata" do
      {:ok, room} = create_room_with_credentials("m-1")

      refute inspect(room.provider_data) =~ @secret
      refute inspect(JitsiProvider.generate_meeting_metadata(room)) =~ @secret
    end

    test "keeps the credentials out of the inspected room data" do
      {:ok, room} = create_room_with_credentials("m-1")

      assert room.provider_config.client_secret == @secret
      refute inspect(room) =~ @secret
    end
  end

  describe "validate_config/1" do
    test "requires a server URL" do
      assert JitsiProvider.validate_config(%{}) == {:error, "Base URL is required"}
      assert JitsiProvider.validate_config(%{base_url: ""}) == {:error, "Base URL is required"}

      assert JitsiProvider.validate_config(%{base_url: "ftp://x.example"}) ==
               {:error, "Invalid URL format. Please provide a valid HTTP/HTTPS URL."}
    end

    test "refuses a server URL with a query string or a fragment, and accepts a sub-path" do
      assert {:error, _message} =
               JitsiProvider.validate_config(%{base_url: "https://m.example.com/?x=1"})

      assert {:error, _message} =
               JitsiProvider.validate_config(%{base_url: "https://m.example.com/#room"})

      assert JitsiProvider.validate_config(%{base_url: "https://example.com/jitsi"}) == :ok
    end

    test "accepts a server URL with no credentials" do
      assert JitsiProvider.validate_config(%{base_url: @base_url}) == :ok

      assert JitsiProvider.validate_config(%{
               base_url: @base_url,
               client_id: nil,
               client_secret: ""
             }) ==
               :ok
    end

    test "accepts a complete credential pair" do
      assert JitsiProvider.validate_config(credential_config()) == :ok
    end

    test "refuses plain http on a public server when tokens would travel in the links" do
      assert {:error, message} =
               JitsiProvider.validate_config(
                 credential_config(base_url: "http://meet.example.com")
               )

      assert message =~ "https://"
    end

    test "refuses plain http on a public server when the credentials only arrive padded" do
      config =
        credential_config(
          base_url: "http://meet.example.com",
          client_id: "  #{@app_id}  ",
          client_secret: " #{@secret} "
        )

      assert {:error, message} = JitsiProvider.validate_config(config)
      assert message =~ "https://"
    end

    test "allows plain http without credentials, and on a local server with them" do
      assert JitsiProvider.validate_config(%{base_url: "http://meet.example.com"}) == :ok

      assert JitsiProvider.validate_config(credential_config(base_url: "http://localhost:8443")) ==
               :ok
    end

    test "refuses a login name and password embedded in the server URL" do
      assert {:error, message} =
               JitsiProvider.validate_config(%{base_url: "https://user:secret@meet.example.com"})

      assert message =~ "login name or password"
    end

    test "refuses half a credential pair, which would silently mint nothing" do
      assert JitsiProvider.validate_config(%{base_url: @base_url, client_id: @app_id}) ==
               {:error, "Enter the App secret that belongs to this App ID"}

      assert JitsiProvider.validate_config(%{base_url: @base_url, client_secret: @secret}) ==
               {:error, "Enter the App ID that belongs to this App secret"}
    end

    test "refuses a secret shorter than 32 bytes and accepts one of exactly 32" do
      assert {:error, message} =
               JitsiProvider.validate_config(
                 credential_config(client_secret: String.duplicate("a", 31))
               )

      assert message =~ "at least 32 bytes"

      assert JitsiProvider.validate_config(
               credential_config(client_secret: String.duplicate("a", 32))
             ) == :ok
    end

    test "treats a whitespace-only credential as absent and measures a secret without its padding" do
      assert JitsiProvider.validate_config(
               credential_config(client_secret: String.duplicate(" ", 32))
             ) == {:error, "Enter the App secret that belongs to this App ID"}

      assert JitsiProvider.validate_config(credential_config(client_id: "   ")) ==
               {:error, "Enter the App ID that belongs to this App secret"}

      assert {:error, message} =
               JitsiProvider.validate_config(
                 credential_config(client_secret: "  " <> String.duplicate("a", 31) <> "  ")
               )

      assert message =~ "at least 32 bytes"
    end
  end

  describe "create_join_url/5 without credentials" do
    test "hands out the bare room URL, with no jwt parameter" do
      {:ok, room} = JitsiProvider.create_meeting_room(%{base_url: @base_url, meeting_id: "m-1"})

      assert JitsiProvider.create_join_url(
               room,
               "Ada",
               "ada@example.com",
               "organizer",
               DateTime.utc_now()
             ) == {:ok, room.meeting_url}
    end
  end

  describe "create_join_url/5 with half the credentials" do
    test "hands out the bare room URL" do
      {:ok, room} = JitsiProvider.create_meeting_room(%{base_url: @base_url, meeting_id: "m-1"})

      for half <- [%{client_id: @app_id}, %{client_secret: @secret}] do
        room_with_half = %{room | provider_config: Map.merge(%{base_url: @base_url}, half)}

        assert JitsiProvider.create_join_url(
                 room_with_half,
                 "Ada",
                 "ada@example.com",
                 "organizer",
                 nil
               ) == {:ok, room.meeting_url}
      end
    end
  end

  describe "create_join_url/5 when minting fails" do
    test "hands out the bare room URL and logs neither the secret nor a token" do
      LogCapture.attach()

      # A room with no id is refused by the token minter, which is the one
      # failure reachable without a broken signer.
      room = %RoomData{
        room_id: nil,
        meeting_url: @base_url <> "/unminted-room",
        provider_data: %{},
        provider_config: credential_config()
      }

      assert JitsiProvider.create_join_url(room, "Ada", "ada@example.com", "organizer", nil) ==
               {:ok, @base_url <> "/unminted-room"}

      dump = "Failed to mint Jitsi access token" |> LogCapture.await_log() |> LogCapture.dump()
      assert dump =~ "invalid_room"
      refute dump =~ @secret
      refute dump =~ "jwt"
      refute dump =~ "eyJ"
    end
  end

  describe "create_join_url/5 with credentials" do
    test "appends a token for the organiser flagged as moderator" do
      {:ok, room} = create_room_with_credentials("m-1")

      assert {:ok, url} =
               JitsiProvider.create_join_url(
                 room,
                 "Ada",
                 "ada@example.com",
                 "organizer",
                 DateTime.utc_now()
               )

      assert String.starts_with?(url, room.meeting_url <> "?jwt=")

      claims = verified_claims(url)
      assert claims["iss"] == @app_id
      assert claims["aud"] == @app_id

      assert claims["context"]["user"] == %{
               "moderator" => true,
               "name" => "Ada",
               "email" => "ada@example.com"
             }
    end

    test "appends a guest token for the attendee flagged as non-moderator" do
      {:ok, room} = create_room_with_credentials("m-1")

      assert {:ok, url} =
               JitsiProvider.create_join_url(
                 room,
                 "Grace",
                 "grace@example.com",
                 "participant",
                 DateTime.utc_now()
               )

      assert verified_claims(url)["context"]["user"]["moderator"] == false
    end

    test "scopes each token to this room only" do
      {:ok, first} = create_room_with_credentials("m-1")
      {:ok, second} = create_room_with_credentials("m-2")

      {:ok, first_url} =
        JitsiProvider.create_join_url(first, "Ada", "a@example.com", "organizer", nil)

      {:ok, second_url} =
        JitsiProvider.create_join_url(second, "Ada", "a@example.com", "organizer", nil)

      assert verified_claims(first_url)["room"] == first.room_id
      assert verified_claims(second_url)["room"] == second.room_id
      refute first.room_id == second.room_id
    end

    test "expires the token a grace period after the meeting time, and a grace period from now when no time is given" do
      {:ok, room} = create_room_with_credentials("m-1")
      meeting_time = ~U[2027-03-01 10:00:00Z]

      {:ok, scheduled_url} =
        JitsiProvider.create_join_url(room, "Ada", "a@example.com", "participant", meeting_time)

      assert verified_claims(scheduled_url)["exp"] ==
               DateTime.to_unix(meeting_time) + @grace_seconds

      before = DateTime.to_unix(DateTime.utc_now())

      {:ok, unscheduled_url} =
        JitsiProvider.create_join_url(room, "Ada", "a@example.com", "participant", nil)

      after_mint = DateTime.to_unix(DateTime.utc_now())

      exp = verified_claims(unscheduled_url)["exp"]
      assert exp >= before + @grace_seconds
      assert exp <= after_mint + @grace_seconds
    end
  end

  describe "time_bound_join_urls?/1" do
    test "is true with a complete credential pair, whose tokens expire after the meeting" do
      assert JitsiProvider.time_bound_join_urls?(credential_config())
    end

    test "is false without a complete credential pair, whose bare room URL never expires" do
      refute JitsiProvider.time_bound_join_urls?(%{base_url: @base_url})
      refute JitsiProvider.time_bound_join_urls?(%{base_url: @base_url, client_id: @app_id})
      refute JitsiProvider.time_bound_join_urls?(credential_config(client_secret: "   "))
    end
  end

  describe "extract_room_id/1" do
    test "round-trips with the room id" do
      {:ok, room} = JitsiProvider.create_meeting_room(%{base_url: @base_url, meeting_id: "m-1"})

      assert JitsiProvider.extract_room_id(room.meeting_url) == room.room_id
    end
  end

  describe "valid_meeting_url?/1" do
    test "accepts an HTTP room URL and rejects a non-HTTP one or one with no room" do
      assert JitsiProvider.valid_meeting_url?("https://meet.example.com/abc")
      refute JitsiProvider.valid_meeting_url?("ftp://meet.example.com/abc")
      refute JitsiProvider.valid_meeting_url?("https://meet.example.com/")
    end
  end

  describe "build_config/3" do
    test "carries the server, the decrypted credentials and the meeting id" do
      integration = %{base_url: @base_url}
      decrypted = %{client_id: @app_id, client_secret: @secret}

      assert JitsiProvider.build_config(integration, decrypted, meeting_id: "m-1") == %{
               base_url: @base_url,
               client_id: @app_id,
               client_secret: @secret,
               meeting_id: "m-1"
             }
    end
  end

  describe "perform_connection_test/1" do
    test "probes the configured server" do
      expect(Tymeslot.HTTPClientMock, :head, fn "https://meet.example.com", _headers, _opts ->
        {:ok, %Req.Response{status: 200, headers: %{}}}
      end)

      assert JitsiProvider.perform_connection_test(%{base_url: @base_url}) ==
               {:ok, "URL responded with HTTP 200"}
    end
  end

  defp credential_config(overrides \\ []) do
    Map.merge(
      %{base_url: @base_url, client_id: @app_id, client_secret: @secret},
      Map.new(overrides)
    )
  end

  defp create_room_with_credentials(meeting_id) do
    JitsiProvider.create_meeting_room(Map.put(credential_config(), :meeting_id, meeting_id))
  end

  # Verifying against the configured secret, rather than only decoding the
  # payload, also proves the token is signed with it.
  defp verified_claims(url) do
    %URI{query: query} = URI.parse(url)
    %{"jwt" => token} = URI.decode_query(query)

    assert {:ok, claims} = Joken.verify(token, Signer.create("HS256", @secret))
    claims
  end
end
