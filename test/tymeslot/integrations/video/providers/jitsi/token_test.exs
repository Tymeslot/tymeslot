defmodule Tymeslot.Integrations.Video.Providers.Jitsi.TokenTest do
  use ExUnit.Case, async: true

  @moduletag :integrations

  alias Joken.Signer
  alias Tymeslot.Integrations.Video.Providers.Jitsi.Token

  @secret "test-secret-value-at-least-32-chars-long"

  defp mint(overrides) do
    Token.mint(
      Keyword.merge(
        [
          app_id: "my-app",
          secret: @secret,
          room: "abc123def4567890",
          name: "Ada Lovelace",
          email: "ada@example.com",
          moderator: true,
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        ],
        overrides
      )
    )
  end

  defp claims(token) do
    [_header, payload, _signature] = String.split(token, ".")
    payload |> Base.url_decode64!(padding: false) |> Jason.decode!()
  end

  describe "mint/1" do
    test "issues a token whose audience and issuer are the app id" do
      assert {:ok, token} = mint([])
      claims = claims(token)
      assert claims["aud"] == "my-app"
      assert claims["iss"] == "my-app"
    end

    test "scopes the token to one room" do
      assert {:ok, token} = mint([])
      assert claims(token)["room"] == "abc123def4567890"
    end

    test "defaults the subject to the wildcard, but accepts an override" do
      assert {:ok, token} = mint([])
      assert claims(token)["sub"] == "*"

      assert {:ok, token} = mint(sub: "tenant-1")
      assert claims(token)["sub"] == "tenant-1"
    end

    test "carries the participant identity and moderator flag" do
      assert {:ok, token} = mint(moderator: true)
      user = claims(token)["context"]["user"]
      assert user["name"] == "Ada Lovelace"
      assert user["email"] == "ada@example.com"
      assert user["moderator"] == true
    end

    test "marks a guest as non-moderator" do
      assert {:ok, token} = mint(moderator: false, name: "Grace Hopper")
      user = claims(token)["context"]["user"]
      assert user["moderator"] == false
      assert user["name"] == "Grace Hopper"
    end

    test "defaults moderator to false when omitted" do
      opts = [
        app_id: "my-app",
        secret: @secret,
        room: "abc123def4567890",
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      ]

      assert {:ok, token} = Token.mint(opts)
      user = claims(token)["context"]["user"]
      assert user["moderator"] == false
    end

    test "omits absent identity fields instead of carrying them as null" do
      assert {:ok, token} = mint(name: nil, email: nil)
      user = claims(token)["context"]["user"]
      refute Map.has_key?(user, "name")
      refute Map.has_key?(user, "email")
      assert Map.has_key?(user, "moderator")
    end

    test "expires after the supplied time" do
      expires_at = DateTime.add(DateTime.utc_now(), 7200, :second)
      assert {:ok, token} = mint(expires_at: expires_at)
      assert claims(token)["exp"] == DateTime.to_unix(expires_at)
    end

    test "stamps the issued-at time close to now" do
      assert {:ok, token} = mint([])
      iat = claims(token)["iat"]
      assert is_integer(iat)
      assert_in_delta iat, DateTime.to_unix(DateTime.utc_now()), 5
    end

    test "signs with HS256" do
      assert {:ok, token} = mint([])
      [header, _payload, _signature] = String.split(token, ".")
      decoded = header |> Base.url_decode64!(padding: false) |> Jason.decode!()
      assert decoded["alg"] == "HS256"
    end

    test "produces a different signature under a different secret" do
      {:ok, first} = mint([])
      {:ok, second} = mint(secret: String.duplicate("z", 40))
      refute first == second
    end

    test "verifies against the signing secret and fails against another" do
      {:ok, token} = mint([])

      assert {:ok, _claims} = Joken.verify(token, Signer.create("HS256", @secret))

      assert {:error, _reason} =
               Joken.verify(token, Signer.create("HS256", String.duplicate("z", 40)))
    end

    test "refuses to mint without an app id" do
      assert {:error, :missing_app_id} = mint(app_id: nil)
    end

    test "refuses to mint without a secret" do
      assert {:error, :missing_secret} = mint(secret: nil)
    end

    test "refuses to mint for an empty or wildcard room" do
      assert {:error, :invalid_room} = mint(room: "")
      assert {:error, :invalid_room} = mint(room: "*")
    end
  end
end
