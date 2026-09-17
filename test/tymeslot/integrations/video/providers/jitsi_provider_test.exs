defmodule Tymeslot.Integrations.Video.Providers.JitsiProviderTest do
  use ExUnit.Case, async: true

  @moduletag :integrations

  import Mox

  alias Joken.Signer
  alias Tymeslot.Integrations.Video.Providers.JitsiProvider
  alias Tymeslot.Integrations.Video.RoomData

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

    test "refuses a missing meeting id rather than inventing a shared room" do
      assert JitsiProvider.create_meeting_room(%{base_url: @base_url}) ==
               {:error, "A meeting ID is required to create a video room"}
    end

    test "keeps the credentials out of the provider data and the metadata" do
      {:ok, room} = create_room_with_credentials("m-1")

      refute inspect(room.provider_data) =~ @secret
      refute inspect(JitsiProvider.generate_meeting_metadata(room)) =~ @secret
    end
  end

  describe "validate_config/1" do
    test "requires a server URL" do
      assert JitsiProvider.validate_config(%{}) == {:error, "Base URL is required"}
      assert JitsiProvider.validate_config(%{base_url: ""}) == {:error, "Base URL is required"}

      assert JitsiProvider.validate_config(%{base_url: "ftp://x.example"}) ==
               {:error, "Invalid URL format. Please provide a valid HTTP/HTTPS URL."}
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

  describe "extract_room_id/1" do
    test "round-trips with the room id" do
      {:ok, room} = JitsiProvider.create_meeting_room(%{base_url: @base_url, meeting_id: "m-1"})

      assert JitsiProvider.extract_room_id(room.meeting_url) == room.room_id
    end
  end

  describe "valid_meeting_url?/1" do
    test "accepts an HTTP room URL and rejects a non-HTTP one" do
      assert JitsiProvider.valid_meeting_url?("https://meet.example.com/abc")
      refute JitsiProvider.valid_meeting_url?("ftp://meet.example.com/abc")
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
