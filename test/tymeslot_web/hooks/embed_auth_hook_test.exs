defmodule TymeslotWeb.Hooks.EmbedAuthHookTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :hooks
  @moduletag :security

  import Tymeslot.Factory

  alias Phoenix.LiveView.Socket
  alias Tymeslot.Embed.Token
  alias TymeslotWeb.Hooks.EmbedAuthHook

  defp build_socket(assigns \\ %{}, connect_info \\ %{}, opts \\ []) do
    connected = Keyword.get(opts, :connected, false)

    %Socket{
      assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns),
      endpoint: TymeslotWeb.Endpoint,
      transport_pid: if(connected, do: self(), else: nil),
      private: %{connect_info: connect_info}
    }
  end

  describe "on_mount/4 — no embed token" do
    test "continues without changes when no embed_token in session" do
      socket = build_socket()

      assert {:cont, updated_socket} =
               EmbedAuthHook.on_mount(:default, %{}, %{}, socket)

      refute Map.has_key?(updated_socket.assigns, :embedded)
    end

    test "continues without changes when embed_token is nil" do
      socket = build_socket()

      assert {:cont, updated_socket} =
               EmbedAuthHook.on_mount(:default, %{}, %{"embed_token" => nil}, socket)

      refute Map.has_key?(updated_socket.assigns, :embedded)
    end
  end

  describe "on_mount/4 — with embed token" do
    test "assigns embedded=true on disconnected render (origin check deferred)" do
      socket = build_socket()
      token = Token.sign("testuser", "https://example.com")

      assert {:cont, updated_socket} =
               EmbedAuthHook.on_mount(:default, %{}, %{"embed_token" => token}, socket)

      assert updated_socket.assigns.embedded == true
    end

    test "halts with redirect when token has no parent_origin (connected)" do
      socket = build_socket(%{}, %{}, connected: true)
      token = Token.sign("testuser")

      assert {:halt, updated_socket} =
               EmbedAuthHook.on_mount(:default, %{}, %{"embed_token" => token}, socket)

      assert updated_socket.redirected == {:redirect, %{to: "/", status: 302}}
    end

    test "assigns embedded=true when parent_origin matches allowed domain" do
      user = insert(:user)

      profile =
        insert(:profile, user: user, username: "sarah", allowed_embed_domains: ["example.com"])

      socket = build_socket(%{}, %{}, connected: true)
      token = Token.sign(profile.username, "https://example.com")

      assert {:cont, updated_socket} =
               EmbedAuthHook.on_mount(:default, %{}, %{"embed_token" => token}, socket)

      assert updated_socket.assigns.embedded == true
    end

    test "halts with redirect when parent_origin is not allowed" do
      user = insert(:user)

      profile =
        insert(:profile, user: user, username: "sarah", allowed_embed_domains: ["example.com"])

      socket = build_socket(%{}, %{}, connected: true)
      token = Token.sign(profile.username, "https://evil.com")

      assert {:halt, updated_socket} =
               EmbedAuthHook.on_mount(:default, %{}, %{"embed_token" => token}, socket)

      assert updated_socket.redirected == {:redirect, %{to: "/", status: 302}}
    end

    test "halts with redirect for expired token" do
      socket = build_socket(%{}, %{}, connected: true)

      expired_token =
        Phoenix.Token.sign(
          TymeslotWeb.Endpoint,
          "embed_session",
          {"testuser", "https://example.com"},
          signed_at: System.system_time(:second) - 22_000
        )

      assert {:halt, updated_socket} =
               EmbedAuthHook.on_mount(:default, %{}, %{"embed_token" => expired_token}, socket)

      assert updated_socket.redirected == {:redirect, %{to: "/", status: 302}}
    end

    test "halts with redirect for tampered token" do
      socket = build_socket(%{}, %{}, connected: true)

      assert {:halt, updated_socket} =
               EmbedAuthHook.on_mount(:default, %{}, %{"embed_token" => "tampered"}, socket)

      assert updated_socket.redirected == {:redirect, %{to: "/", status: 302}}
    end

    test "halts with redirect for tampered token on disconnected render" do
      socket = build_socket()

      assert {:halt, updated_socket} =
               EmbedAuthHook.on_mount(:default, %{}, %{"embed_token" => "tampered"}, socket)

      assert updated_socket.redirected == {:redirect, %{to: "/", status: 302}}
    end

    test "halts when profile not found for token username" do
      socket = build_socket(%{}, %{}, connected: true)
      token = Token.sign("nonexistent_user", "https://example.com")

      assert {:halt, updated_socket} =
               EmbedAuthHook.on_mount(:default, %{}, %{"embed_token" => token}, socket)

      assert updated_socket.redirected == {:redirect, %{to: "/", status: 302}}
    end
  end

  describe "origin_allowed?/2" do
    test "returns false for nil domains" do
      refute EmbedAuthHook.origin_allowed?("https://example.com", nil)
    end

    test "returns false for empty domain list" do
      refute EmbedAuthHook.origin_allowed?("https://example.com", [])
    end

    test "returns false for [\"none\"] domains" do
      refute EmbedAuthHook.origin_allowed?("https://example.com", ["none"])
    end

    test "matches exact domain" do
      assert EmbedAuthHook.origin_allowed?("https://example.com", ["example.com"])
    end

    test "rejects non-matching domain" do
      refute EmbedAuthHook.origin_allowed?("https://evil.com", ["example.com"])
    end

    test "matches wildcard subdomain" do
      assert EmbedAuthHook.origin_allowed?("https://sub.example.com", ["*.example.com"])
    end

    test "matches deeply nested wildcard subdomain" do
      assert EmbedAuthHook.origin_allowed?("https://a.b.example.com", ["*.example.com"])
    end

    test "wildcard does not match the bare domain itself" do
      refute EmbedAuthHook.origin_allowed?("https://example.com", ["*.example.com"])
    end

    test "rejects suffix attack (malicious-example.com vs *.example.com)" do
      refute EmbedAuthHook.origin_allowed?("https://malicious-example.com", ["*.example.com"])
    end

    test "handles malformed origin URL" do
      refute EmbedAuthHook.origin_allowed?("not-a-url", ["example.com"])
    end

    test "matches with multiple allowed domains" do
      domains = ["example.com", "*.other.com"]
      assert EmbedAuthHook.origin_allowed?("https://example.com", domains)
      assert EmbedAuthHook.origin_allowed?("https://sub.other.com", domains)
      refute EmbedAuthHook.origin_allowed?("https://evil.com", domains)
    end

    test "auto-matches www variant when bare domain is whitelisted" do
      assert EmbedAuthHook.origin_allowed?("https://www.example.com", ["example.com"])
    end

    test "auto-matches bare domain when www variant is whitelisted" do
      assert EmbedAuthHook.origin_allowed?("https://example.com", ["www.example.com"])
    end

    test "www auto-matching does not affect unrelated domains" do
      refute EmbedAuthHook.origin_allowed?("https://www.evil.com", ["example.com"])
    end

    test "www-variant matching works for domains starting with w" do
      # Regression: String.trim_leading("www.widget.com", "www.") strips character-by-character,
      # producing "idget.com" instead of "widget.com"
      assert EmbedAuthHook.origin_allowed?("https://widget.com", ["www.widget.com"])
      assert EmbedAuthHook.origin_allowed?("https://www.widget.com", ["widget.com"])
    end

    test "wildcard does not match dot-prefixed host" do
      refute EmbedAuthHook.origin_allowed?("https://.example.com", ["*.example.com"])
    end

    test "matches localhost origins on any port" do
      assert EmbedAuthHook.origin_allowed?("http://localhost:4000", ["localhost"])
    end

    test "matches http scheme for localhost" do
      assert EmbedAuthHook.origin_allowed?("http://localhost", ["localhost"])
    end

    test "rejects origin with path or query (URI.parse host extraction)" do
      # URI.parse should extract just the host, ignoring path/query
      assert EmbedAuthHook.origin_allowed?("https://example.com/some/path?q=1", ["example.com"])
    end

    test "does not match uppercase origin against lowercase domain (origins are case-sensitive)" do
      # Browsers always send lowercase origins, so case-insensitive matching
      # is not required. This test documents the current behavior.
      refute EmbedAuthHook.origin_allowed?("https://EXAMPLE.COM", ["example.com"])
    end
  end

  describe "on_mount/4 — edge cases" do
    test "assigns embedded=true when www parent_origin matches bare domain allowlist (connected)" do
      user = insert(:user)

      profile =
        insert(:profile,
          user: user,
          username: "wwwtest",
          allowed_embed_domains: ["example.com"]
        )

      socket = build_socket(%{}, %{}, connected: true)
      token = Token.sign(profile.username, "https://www.example.com")

      assert {:cont, updated_socket} =
               EmbedAuthHook.on_mount(:default, %{}, %{"embed_token" => token}, socket)

      assert updated_socket.assigns.embedded == true
    end

    test "halts when profile has [\"none\"] sentinel" do
      user = insert(:user)

      profile =
        insert(:profile,
          user: user,
          username: "nonetest",
          allowed_embed_domains: ["none"]
        )

      socket = build_socket(%{}, %{}, connected: true)
      token = Token.sign(profile.username, "https://example.com")

      assert {:halt, updated_socket} =
               EmbedAuthHook.on_mount(:default, %{}, %{"embed_token" => token}, socket)

      assert updated_socket.redirected == {:redirect, %{to: "/", status: 302}}
    end

    test "halts when profile has empty allowed domains" do
      user = insert(:user)

      profile =
        insert(:profile, user: user, username: "emptydomains", allowed_embed_domains: [])

      socket = build_socket(%{}, %{}, connected: true)
      token = Token.sign(profile.username, "https://example.com")

      assert {:halt, updated_socket} =
               EmbedAuthHook.on_mount(:default, %{}, %{"embed_token" => token}, socket)

      assert updated_socket.redirected == {:redirect, %{to: "/", status: 302}}
    end

    test "halts when profile has nil allowed_embed_domains" do
      user = insert(:user)

      profile =
        insert(:profile, user: user, username: "nulldomains", allowed_embed_domains: nil)

      socket = build_socket(%{}, %{}, connected: true)
      token = Token.sign(profile.username, "https://example.com")

      assert {:halt, updated_socket} =
               EmbedAuthHook.on_mount(:default, %{}, %{"embed_token" => token}, socket)

      assert updated_socket.redirected == {:redirect, %{to: "/", status: 302}}
    end
  end
end
