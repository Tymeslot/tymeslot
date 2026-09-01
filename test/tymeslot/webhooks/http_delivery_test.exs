defmodule Tymeslot.Webhooks.HttpDeliveryTest do
  @moduledoc """
  Unit tests for `Tymeslot.Webhooks.HttpDelivery`.

  Tests call `HttpDelivery.post/3` directly, mocking `Tymeslot.HTTPClientMock`
  at the HTTP boundary. No database access or Oban worker state is involved.
  """

  use ExUnit.Case, async: false

  @moduletag :security
  @moduletag :unit

  import Mox
  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Webhooks.HttpDelivery

  # Must match @max_redirects in HttpDelivery.
  @max_redirects 5

  setup :verify_on_exit!

  setup do
    setup_config(:tymeslot,
      http_client_module: Tymeslot.HTTPClientMock,
      environment: :test
    )

    :ok
  end

  # ────────────────────────────────────────────────────────────────────────────
  # Successful delivery
  # ────────────────────────────────────────────────────────────────────────────

  describe "post/3 - successful delivery" do
    test "returns {:ok, status, body} on a direct 200 response" do
      expect(Tymeslot.HTTPClientMock, :post, fn "https://example.com/hook",
                                                "payload",
                                                _headers,
                                                _opts ->
        {:ok, %Req.Response{status: 200, body: "OK"}}
      end)

      assert {:ok, 200, "OK"} =
               HttpDelivery.post("https://example.com/hook", "payload", [])
    end

    test "returns {:ok, status, body} on a 201 response" do
      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 201, body: ~s({"id":"abc"})}}
      end)

      assert {:ok, 201, ~s({"id":"abc"})} =
               HttpDelivery.post("https://example.com/hook", "{}", [
                 {"Content-Type", "application/json"}
               ])
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # SSRF protection on the initial URL
  # ────────────────────────────────────────────────────────────────────────────

  describe "post/3 - initial URL SSRF check" do
    test "blocks delivery to a private IPv4 address in production" do
      with_config(:tymeslot, environment: :prod)

      # HTTP client must never be called when the initial URL is blocked.
      expect(Tymeslot.HTTPClientMock, :post, 0, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: "Should not reach here"}}
      end)

      assert {:error, :blocked_by_ssrf} =
               HttpDelivery.post("https://10.0.0.1/hook", "payload", [])
    end

    test "blocks delivery to loopback in production" do
      with_config(:tymeslot, environment: :prod)

      expect(Tymeslot.HTTPClientMock, :post, 0, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: "unreachable"}}
      end)

      assert {:error, :blocked_by_ssrf} =
               HttpDelivery.post("https://127.0.0.1/hook", "payload", [])
    end

    test "blocks delivery to link-local range in production" do
      with_config(:tymeslot, environment: :prod)

      expect(Tymeslot.HTTPClientMock, :post, 0, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: "unreachable"}}
      end)

      assert {:error, :blocked_by_ssrf} =
               HttpDelivery.post("https://169.254.169.254/latest/meta-data", "payload", [])
    end

    test "blocks delivery to IPv6 ULA address in production" do
      with_config(:tymeslot, environment: :prod)

      expect(Tymeslot.HTTPClientMock, :post, 0, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: "unreachable"}}
      end)

      assert {:error, :blocked_by_ssrf} =
               HttpDelivery.post("https://[fc00::1]/hook", "payload", [])
    end

    test "allows private-range URLs in non-production environments" do
      with_config(:tymeslot, environment: :test)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: "OK"}}
      end)

      assert {:ok, 200, "OK"} =
               HttpDelivery.post("http://169.254.169.254/test", "payload", [])
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # Redirect method switching (RFC 9110 §15.4)
  # ────────────────────────────────────────────────────────────────────────────

  describe "post/3 - redirect method switching" do
    test "301 redirect switches to GET and drops body" do
      Tymeslot.HTTPClientMock
      |> expect(:post, fn "https://example.com/hook", _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 301,
           body: "",
           headers: %{"location" => ["https://example.com/new-path"]}
         }}
      end)
      |> expect(:get, fn "https://example.com/new-path", _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: "moved"}}
      end)

      assert {:ok, 200, "moved"} =
               HttpDelivery.post("https://example.com/hook", "body-payload", [])
    end

    test "302 redirect switches to GET and drops body" do
      Tymeslot.HTTPClientMock
      |> expect(:post, fn "https://example.com/hook", _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 302,
           body: "",
           headers: %{"location" => ["https://example.com/found"]}
         }}
      end)
      |> expect(:get, fn "https://example.com/found", _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: "found"}}
      end)

      assert {:ok, 200, "found"} =
               HttpDelivery.post("https://example.com/hook", "body-payload", [])
    end

    test "303 redirect switches to GET and drops body" do
      Tymeslot.HTTPClientMock
      |> expect(:post, fn "https://example.com/hook", _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 303,
           body: "",
           headers: %{"location" => ["https://example.com/see-other"]}
         }}
      end)
      |> expect(:get, fn "https://example.com/see-other", _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: "see other"}}
      end)

      assert {:ok, 200, "see other"} =
               HttpDelivery.post("https://example.com/hook", "body-payload", [])
    end

    test "307 redirect preserves POST method and body" do
      original_body = ~s({"event":"created"})

      Tymeslot.HTTPClientMock
      |> expect(:post, fn "https://example.com/hook", ^original_body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 307,
           body: "",
           headers: %{"location" => ["https://example.com/temporary"]}
         }}
      end)
      |> expect(:post, fn "https://example.com/temporary", ^original_body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: "accepted"}}
      end)

      assert {:ok, 200, "accepted"} =
               HttpDelivery.post("https://example.com/hook", original_body, [])
    end

    test "308 redirect preserves POST method and body" do
      original_body = ~s({"event":"updated"})

      Tymeslot.HTTPClientMock
      |> expect(:post, fn "https://example.com/hook", ^original_body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 308,
           body: "",
           headers: %{"location" => ["https://example.com/permanent"]}
         }}
      end)
      |> expect(:post, fn "https://example.com/permanent", ^original_body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: "accepted"}}
      end)

      assert {:ok, 200, "accepted"} =
               HttpDelivery.post("https://example.com/hook", original_body, [])
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # Redirect header sanitisation
  # (moved from webhook_worker_security_test.exs lines 229–319)
  # ────────────────────────────────────────────────────────────────────────────

  describe "post/3 - redirect header sanitisation" do
    test "strips X-Tymeslot-Token when redirect crosses to a different host" do
      test_pid = self()
      token = "test-token-value"

      initial_headers = [
        {"X-Tymeslot-Token", token},
        {"Content-Type", "application/json"}
      ]

      Tymeslot.HTTPClientMock
      |> expect(:post, fn "https://example.com/webhook", _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 301,
           body: "",
           headers: %{"location" => ["https://other.example.com/new-endpoint"]}
         }}
      end)
      |> expect(:get, fn "https://other.example.com/new-endpoint", headers, _opts ->
        send(test_pid, {:second_request_headers, headers})
        {:ok, %Req.Response{status: 200, body: "OK"}}
      end)

      assert {:ok, 200, "OK"} =
               HttpDelivery.post("https://example.com/webhook", "payload", initial_headers)

      assert_received {:second_request_headers, second_headers}

      refute Enum.any?(second_headers, fn
               {"X-Tymeslot-Token", _value} -> true
               _other -> false
             end),
             "X-Tymeslot-Token must not be forwarded to a different origin"
    end

    test "preserves X-Tymeslot-Token when redirect stays on the same host" do
      test_pid = self()
      token = "same-origin-token"

      initial_headers = [
        {"X-Tymeslot-Token", token},
        {"Content-Type", "application/json"}
      ]

      Tymeslot.HTTPClientMock
      |> expect(:post, fn "https://example.com/webhook", _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 301,
           body: "",
           headers: %{"location" => ["https://example.com/new-path"]}
         }}
      end)
      |> expect(:get, fn "https://example.com/new-path", headers, _opts ->
        send(test_pid, {:second_request_headers, headers})
        {:ok, %Req.Response{status: 200, body: "OK"}}
      end)

      assert {:ok, 200, "OK"} =
               HttpDelivery.post("https://example.com/webhook", "payload", initial_headers)

      assert_received {:second_request_headers, second_headers}

      assert Enum.any?(second_headers, fn
               {"X-Tymeslot-Token", _value} -> true
               _other -> false
             end),
             "X-Tymeslot-Token must be preserved for same-origin redirects"
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # Redirect error cases
  # (moved from webhook_worker_security_test.exs lines 348–398)
  # ────────────────────────────────────────────────────────────────────────────

  describe "post/3 - redirect error cases" do
    test "follows exactly @max_redirects hops, delivering on the last one" do
      # A budget of #{@max_redirects} redirects means the request after the
      # #{@max_redirects}th hop is still ours to make: 1 POST + #{@max_redirects}
      # GETs. A guard that fires when the counter reaches 0 rather than when it
      # drops below it stops one hop early and fails this with
      # :too_many_redirects, which is what `post/3` did until the counter was
      # corrected.
      Tymeslot.HTTPClientMock
      |> expect(:post, 1, fn url, _body, _headers, _opts ->
        {:ok, redirect_from(url)}
      end)
      |> expect(:get, @max_redirects, fn url, _headers, _opts ->
        if hop_index(url) == @max_redirects do
          {:ok, %Req.Response{status: 200, body: "final"}}
        else
          {:ok, redirect_from(url)}
        end
      end)

      assert {:ok, 200, "final"} = HttpDelivery.post(hop_url(0), "payload", [])
    end

    test "returns {:error, :too_many_redirects} one hop past the budget" do
      # Every hop redirects, so the chain runs 1 POST + #{@max_redirects} GETs
      # and then refuses. `verify_on_exit!` fails the test if a
      # #{@max_redirects + 1}th GET is attempted, pinning the upper bound as
      # well as the lower one.
      Tymeslot.HTTPClientMock
      |> expect(:post, 1, fn url, _body, _headers, _opts ->
        {:ok, redirect_from(url)}
      end)
      |> expect(:get, @max_redirects, fn url, _headers, _opts ->
        {:ok, redirect_from(url)}
      end)

      assert {:error, :too_many_redirects} = HttpDelivery.post(hop_url(0), "payload", [])
    end

    test "returns {:error, :redirect_missing_location} when 3xx response has no Location header" do
      expect(Tymeslot.HTTPClientMock, :post, 1, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 301, body: "", headers: %{}}}
      end)

      assert {:error, :redirect_missing_location} =
               HttpDelivery.post("https://example.com/webhook", "payload", [])
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # Protocol-relative Location headers
  # (moved from webhook_worker_security_test.exs lines 405–469)
  # ────────────────────────────────────────────────────────────────────────────

  describe "post/3 - protocol-relative Location header" do
    test "blocks a protocol-relative redirect to a private IP" do
      with_config(:tymeslot, environment: :prod)

      # Only one HTTP call — the redirect target fails SSRF re-check.
      expect(Tymeslot.HTTPClientMock, :post, 1, fn _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 301,
           body: "",
           headers: %{"location" => ["//127.0.0.1/bad"]}
         }}
      end)

      assert {:error, :blocked_redirect} =
               HttpDelivery.post("https://example.com/webhook", "payload", [])
    end

    test "treats a protocol-relative redirect to a public host as cross-origin and strips the token" do
      test_pid = self()
      token = "proto-relative-token"

      initial_headers = [{"X-Tymeslot-Token", token}]

      Tymeslot.HTTPClientMock
      |> expect(:post, fn "https://example.com/webhook", _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 301,
           body: "",
           headers: %{"location" => ["//other.example.com/ok"]}
         }}
      end)
      |> expect(:get, fn "https://other.example.com/ok", headers, _opts ->
        send(test_pid, {:second_request_headers, headers})
        {:ok, %Req.Response{status: 200, body: "OK"}}
      end)

      assert {:ok, 200, "OK"} =
               HttpDelivery.post("https://example.com/webhook", "payload", initial_headers)

      assert_received {:second_request_headers, second_headers}

      # Cross-origin redirect — token must be stripped.
      refute Enum.any?(second_headers, fn
               {"X-Tymeslot-Token", _value} -> true
               _other -> false
             end),
             "X-Tymeslot-Token must not be forwarded when a protocol-relative redirect crosses hosts"
    end

    test "resolves a protocol-relative Location using the original request scheme" do
      # A protocol-relative URL like //other.example.com/ok from an https origin
      # must resolve to https://other.example.com/ok, not http://.
      Tymeslot.HTTPClientMock
      |> expect(:post, fn "https://example.com/webhook", _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 301,
           body: "",
           headers: %{"location" => ["//other.example.com/resolved"]}
         }}
      end)
      |> expect(:get, fn resolved_url, _headers, _opts ->
        assert resolved_url == "https://other.example.com/resolved",
               "Protocol-relative Location must inherit the originating scheme (https)"

        {:ok, %Req.Response{status: 200, body: "OK"}}
      end)

      assert {:ok, 200, "OK"} =
               HttpDelivery.post("https://example.com/webhook", "payload", [])
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # Redirect SSRF re-check on each hop
  # ────────────────────────────────────────────────────────────────────────────

  describe "post/3 - SSRF re-check on redirect hops" do
    test "blocks a redirect to loopback even when the initial URL is public" do
      with_config(:tymeslot, environment: :prod)

      # Exactly one HTTP call — the redirect target fails SSRF re-check.
      expect(Tymeslot.HTTPClientMock, :post, 1, fn _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 301,
           body: "",
           headers: %{"location" => ["http://127.0.0.1:8080/internal"]}
         }}
      end)

      assert {:error, :blocked_redirect} =
               HttpDelivery.post("https://example.com/webhook", "payload", [])
    end

    test "blocks a redirect to link-local range" do
      with_config(:tymeslot, environment: :prod)

      expect(Tymeslot.HTTPClientMock, :post, 1, fn _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 302,
           body: "",
           headers: %{"location" => ["http://169.254.169.254/latest/meta-data/"]}
         }}
      end)

      assert {:error, :blocked_redirect} =
               HttpDelivery.post("https://example.com/webhook", "payload", [])
    end

    test "refuses a hop that downgrades to plain http in production" do
      with_config(:tymeslot, environment: :prod)

      expect(Tymeslot.HTTPClientMock, :post, 1, fn _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 301,
           body: "",
           headers: %{"location" => ["http://203.0.113.10/hook"]}
         }}
      end)

      assert {:error, :blocked_redirect} =
               HttpDelivery.post("https://example.com/webhook", "payload", [])
    end

    test "follows the same public host over https in production" do
      # The mirror of the test above, and the reason it can only be passing for
      # the scheme: 203.0.113.10 is TEST-NET-3, so nothing about the address
      # itself is what refuses the http hop.
      with_config(:tymeslot, environment: :prod)

      Tymeslot.HTTPClientMock
      |> expect(:post, 1, fn _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 301,
           body: "",
           headers: %{"location" => ["https://203.0.113.10/hook"]}
         }}
      end)
      |> expect(:get, 1, fn "https://203.0.113.10/hook", _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: "OK"}}
      end)

      assert {:ok, 200, "OK"} =
               HttpDelivery.post("https://example.com/webhook", "payload", [])
    end

    test "refuses a hop to a scheme that is not http at all" do
      expect(Tymeslot.HTTPClientMock, :post, 1, fn _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 302,
           body: "",
           headers: %{"location" => ["ftp://files.example.com/payload"]}
         }}
      end)

      assert {:error, :blocked_redirect} =
               HttpDelivery.post("https://example.com/webhook", "payload", [])
    end

    test "follows a public-to-public redirect successfully" do
      Tymeslot.HTTPClientMock
      |> expect(:post, fn "https://example.com/webhook", _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 301,
           body: "",
           headers: %{"location" => ["https://other.example.com/webhook"]}
         }}
      end)
      |> expect(:get, fn "https://other.example.com/webhook", _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: "OK"}}
      end)

      assert {:ok, 200, "OK"} =
               HttpDelivery.post("https://example.com/webhook", "payload", [])
    end
  end

  # A chain of distinct hop URLs, so the stub's answer is derived from its
  # argument rather than echoing a fixed response back at the assertion.
  defp hop_url(n), do: "https://hop.example.com/#{n}"

  defp hop_index(url), do: url |> String.split("/") |> List.last() |> String.to_integer()

  defp redirect_from(url) do
    %Req.Response{
      status: 301,
      body: "",
      headers: %{"location" => [hop_url(hop_index(url) + 1)]}
    }
  end
end
