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

    test "scopes the token to one room and never to a wildcard" do
      assert {:ok, token} = mint([])
      claims = claims(token)
      assert claims["room"] == "abc123def4567890"
      refute claims["room"] == "*"
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

    test "expires after the supplied time" do
      expires_at = DateTime.add(DateTime.utc_now(), 7200, :second)
      assert {:ok, token} = mint(expires_at: expires_at)
      assert claims(token)["exp"] == DateTime.to_unix(expires_at)
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

    test "refuses to mint without an app id or secret" do
      assert {:error, _reason} = mint(app_id: nil)
      assert {:error, _reason} = mint(secret: nil)
    end

    test "refuses to mint for an empty or wildcard room" do
      assert {:error, _reason} = mint(room: "")
      assert {:error, _reason} = mint(room: "*")
    end
  end
end
