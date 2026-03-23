defmodule Tymeslot.Integrations.Common.OAuth.IdTokenTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Common.OAuth.IdToken

  # Helper to build a fake JWT with given claims
  defp build_jwt(claims) do
    header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256", "typ" => "JWT"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(claims), padding: false)
    signature = Base.url_encode64("fake-signature", padding: false)
    "#{header}.#{payload}.#{signature}"
  end

  describe "decode/1" do
    test "decodes Google id_token with sub and email" do
      jwt =
        build_jwt(%{
          "sub" => "118234567890",
          "email" => "mark@gmail.com",
          "iss" => "accounts.google.com"
        })

      assert {:ok, claims} = IdToken.decode(jwt)
      assert claims.sub == "118234567890"
      assert claims.email == "mark@gmail.com"
    end

    test "decodes Microsoft id_token with oid, tid, and preferred_username" do
      jwt =
        build_jwt(%{
          "oid" => "a1b2c3d4-e5f6",
          "tid" => "tenant-123",
          "preferred_username" => "mark@company.com",
          "email" => "mark@company.com"
        })

      assert {:ok, claims} = IdToken.decode(jwt)
      assert claims.oid == "a1b2c3d4-e5f6"
      assert claims.tid == "tenant-123"
      assert claims.email == "mark@company.com"
    end

    test "falls back to preferred_username when email is absent" do
      jwt = build_jwt(%{"oid" => "abc", "preferred_username" => "user@tenant.com"})
      assert {:ok, claims} = IdToken.decode(jwt)
      assert claims.email == "user@tenant.com"
    end

    test "handles missing optional claims gracefully" do
      jwt = build_jwt(%{"sub" => "12345"})
      assert {:ok, claims} = IdToken.decode(jwt)
      assert claims.sub == "12345"
      assert is_nil(claims.email)
      assert is_nil(claims.oid)
      assert is_nil(claims.tid)
    end

    test "returns error for nil input" do
      assert {:error, :invalid_token} = IdToken.decode(nil)
    end

    test "returns error for malformed JWT (not 3 segments)" do
      assert {:error, :invalid_token} = IdToken.decode("only.two")
      assert {:error, :invalid_token} = IdToken.decode("no-dots")
    end

    test "returns error for invalid base64 payload" do
      assert {:error, :invalid_token} = IdToken.decode("valid.!!!invalid!!!.sig")
    end

    test "returns error for invalid JSON payload" do
      payload = Base.url_encode64("not json", padding: false)
      assert {:error, :invalid_token} = IdToken.decode("header.#{payload}.sig")
    end
  end
end
