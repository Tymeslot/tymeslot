defmodule Tymeslot.Integrations.Calendar.CalDAV.DigestAuthTest do
  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :unit

  alias Req.Response
  alias Tymeslot.Integrations.Calendar.CalDAV.DigestAuth

  # RFC 7616, Section 3.9.1. Every input below is taken from the published
  # example, including the client nonce, so the expected response is a value
  # the RFC itself asserts rather than a second computation of the same
  # formula. A mistake anywhere — HA1, HA2, the field order inside the
  # response hash, the choice of hash — produces a different digest.
  @rfc_username "Mufasa"
  @rfc_password "Circle of Life"
  @rfc_url "http://www.example.com/dir/index.html"
  @rfc_nonce "7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v"
  @rfc_opaque "FQhe/qaU925kfnzjCev0ciny7QMkPqMAFRtzCUYo5tdS"
  @rfc_cnonce "f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZJ"
  @rfc_realm "http-auth@example.org"

  defp challenge_response(value) do
    Response.put_header(Response.new(status: 401), "www-authenticate", value)
  end

  defp rfc_challenge(algorithm) do
    challenge_response(
      ~s(Digest realm="#{@rfc_realm}", qop="auth, auth-int", algorithm=#{algorithm}, ) <>
        ~s(nonce="#{@rfc_nonce}", opaque="#{@rfc_opaque}")
    )
  end

  defp rfc_authorization(algorithm) do
    {:ok, {"Authorization", value}} =
      DigestAuth.build_authorization(
        rfc_challenge(algorithm),
        "GET",
        @rfc_url,
        @rfc_username,
        @rfc_password,
        client_nonce: @rfc_cnonce
      )

    value
  end

  # Parses `Digest k=v, k="v"` back into a map so assertions name the field
  # they care about rather than depending on the order they are emitted in.
  defp fields(header_value) do
    "Digest " <> params = header_value

    params
    |> String.split(~r/,\s*(?=[A-Za-z0-9_-]+=)/)
    |> Map.new(fn param ->
      [key, value] = String.split(param, "=", parts: 2)
      {key, String.trim(value, ~s("))}
    end)
  end

  describe "build_authorization/6 against the RFC 7616 vectors" do
    test "computes the published MD5 response" do
      assert %{"response" => "8ca523f5e9506fed4657c9700eebdbec"} =
               fields(rfc_authorization("MD5"))
    end

    test "computes the published SHA-256 response" do
      assert %{
               "response" => "753927fa0e85d155564e2e272a28d1802ca10daf4496794697cf8db5856cb6c1"
             } = fields(rfc_authorization("SHA-256"))
    end

    test "echoes the challenge's realm, nonce, opaque and algorithm back verbatim" do
      assert %{
               "username" => @rfc_username,
               "realm" => @rfc_realm,
               "nonce" => @rfc_nonce,
               "opaque" => @rfc_opaque,
               "algorithm" => "SHA-256"
             } = fields(rfc_authorization("SHA-256"))
    end

    test "digests the request target, not the whole URL" do
      assert %{"uri" => "/dir/index.html"} = fields(rfc_authorization("MD5"))
    end

    test "selects auth from a qop list that also offers auth-int" do
      assert %{"qop" => "auth", "nc" => "00000001", "cnonce" => @rfc_cnonce} =
               fields(rfc_authorization("MD5"))
    end
  end

  describe "build_authorization/6 challenge handling" do
    test "answers a challenge that omits algorithm, defaulting to MD5" do
      # Same inputs as the RFC MD5 vector with the algorithm parameter dropped;
      # RFC 2617 makes MD5 the default, so the response must be unchanged.
      response =
        challenge_response(
          ~s(Digest realm="#{@rfc_realm}", qop="auth", nonce="#{@rfc_nonce}", ) <>
            ~s(opaque="#{@rfc_opaque}")
        )

      assert {:ok, {"Authorization", value}} =
               DigestAuth.build_authorization(
                 response,
                 "GET",
                 @rfc_url,
                 @rfc_username,
                 @rfc_password,
                 client_nonce: @rfc_cnonce
               )

      assert %{"response" => "8ca523f5e9506fed4657c9700eebdbec"} = fields(value)
      refute Map.has_key?(fields(value), "algorithm")
    end

    test "omits nc and cnonce for the legacy no-qop form" do
      response =
        challenge_response(~s(Digest realm="#{@rfc_realm}", nonce="#{@rfc_nonce}"))

      assert {:ok, {"Authorization", value}} =
               DigestAuth.build_authorization(
                 response,
                 "PROPFIND",
                 @rfc_url,
                 @rfc_username,
                 @rfc_password
               )

      parsed = fields(value)
      refute Map.has_key?(parsed, "qop")
      refute Map.has_key?(parsed, "nc")
      refute Map.has_key?(parsed, "cnonce")
      assert Map.has_key?(parsed, "response")
    end

    test "MD5-sess folds the nonces into HA1, changing the response" do
      plain =
        DigestAuth.build_authorization(
          rfc_challenge("MD5"),
          "GET",
          @rfc_url,
          @rfc_username,
          @rfc_password,
          client_nonce: @rfc_cnonce
        )

      sess =
        DigestAuth.build_authorization(
          rfc_challenge("MD5-sess"),
          "GET",
          @rfc_url,
          @rfc_username,
          @rfc_password,
          client_nonce: @rfc_cnonce
        )

      {:ok, {"Authorization", plain_value}} = plain
      {:ok, {"Authorization", sess_value}} = sess

      assert fields(plain_value)["response"] != fields(sess_value)["response"]
      assert fields(sess_value)["algorithm"] == "MD5-sess"
    end

    test "binds the HTTP method, so a header built for one method does not answer another" do
      propfind =
        DigestAuth.build_authorization(
          rfc_challenge("MD5"),
          "PROPFIND",
          @rfc_url,
          @rfc_username,
          @rfc_password,
          client_nonce: @rfc_cnonce
        )

      {:ok, {"Authorization", propfind_value}} = propfind

      assert fields(propfind_value)["response"] != fields(rfc_authorization("MD5"))["response"]
    end

    test "keeps the Digest realm when a Basic challenge follows it in the same header" do
      response =
        challenge_response(
          ~s(Digest realm="#{@rfc_realm}", qop="auth", nonce="#{@rfc_nonce}", ) <>
            ~s(opaque="#{@rfc_opaque}", Basic realm="some other realm")
        )

      assert {:ok, {"Authorization", value}} =
               DigestAuth.build_authorization(
                 response,
                 "GET",
                 @rfc_url,
                 @rfc_username,
                 @rfc_password,
                 client_nonce: @rfc_cnonce
               )

      assert %{"realm" => @rfc_realm, "response" => "8ca523f5e9506fed4657c9700eebdbec"} =
               fields(value)
    end

    test "finds the Digest challenge when it arrives as a separate header from Basic" do
      response =
        Response.new(status: 401)
        |> Response.put_header("www-authenticate", ~s(Basic realm="other"))
        |> Response.put_header(
          "www-authenticate",
          ~s(Digest realm="#{@rfc_realm}", qop="auth", nonce="#{@rfc_nonce}")
        )

      assert {:ok, {"Authorization", value}} =
               DigestAuth.build_authorization(
                 response,
                 "GET",
                 @rfc_url,
                 @rfc_username,
                 @rfc_password,
                 client_nonce: @rfc_cnonce
               )

      assert fields(value)["realm"] == @rfc_realm
    end

    test "generates a different client nonce on each call" do
      values =
        for _attempt <- 1..5 do
          {:ok, {"Authorization", value}} =
            DigestAuth.build_authorization(
              rfc_challenge("MD5"),
              "GET",
              @rfc_url,
              @rfc_username,
              @rfc_password
            )

          fields(value)["cnonce"]
        end

      assert length(Enum.uniq(values)) == 5
    end
  end

  describe "build_authorization/6 when the challenge cannot be answered" do
    test "reports :none for a 401 carrying no challenge at all" do
      assert :none =
               DigestAuth.build_authorization(
                 Response.new(status: 401),
                 "GET",
                 @rfc_url,
                 @rfc_username,
                 @rfc_password
               )
    end

    test "reports :none for a Basic-only challenge" do
      assert :none =
               DigestAuth.build_authorization(
                 challenge_response(~s(Basic realm="#{@rfc_realm}")),
                 "GET",
                 @rfc_url,
                 @rfc_username,
                 @rfc_password
               )
    end

    test "reports :none for a Digest challenge with no nonce to answer" do
      assert :none =
               DigestAuth.build_authorization(
                 challenge_response(~s(Digest realm="#{@rfc_realm}", qop="auth")),
                 "GET",
                 @rfc_url,
                 @rfc_username,
                 @rfc_password
               )
    end

    test "names the algorithm it cannot compute" do
      response =
        challenge_response(
          ~s(Digest realm="#{@rfc_realm}", qop="auth", algorithm=SHA-1, nonce="#{@rfc_nonce}")
        )

      assert {:unsupported, detail} =
               DigestAuth.build_authorization(
                 response,
                 "GET",
                 @rfc_url,
                 @rfc_username,
                 @rfc_password
               )

      assert detail =~ "sha-1"
    end

    test "names the qop it cannot compute when only auth-int is offered" do
      response =
        challenge_response(
          ~s(Digest realm="#{@rfc_realm}", qop="auth-int", nonce="#{@rfc_nonce}")
        )

      assert {:unsupported, detail} =
               DigestAuth.build_authorization(
                 response,
                 "GET",
                 @rfc_url,
                 @rfc_username,
                 @rfc_password
               )

      assert detail =~ "auth-int"
    end
  end
end
