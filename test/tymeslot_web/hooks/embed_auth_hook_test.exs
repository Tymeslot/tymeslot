defmodule TymeslotWeb.Hooks.EmbedAuthHookTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :hooks
  @moduletag :security

  import Tymeslot.Factory

  alias Phoenix.LiveView.Socket
  alias Tymeslot.Embed.Token
  alias TymeslotWeb.Hooks.EmbedAuthHook

  defp build_socket(assigns \\ %{}, connect_info \\ %{}) do
    %Socket{
      assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns),
      endpoint: TymeslotWeb.Endpoint,
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
    test "assigns embedded=true with valid token and no origin header" do
      socket = build_socket(%{}, %{x_headers: []})
      token = Token.sign("testuser")

      assert {:cont, updated_socket} =
               EmbedAuthHook.on_mount(:default, %{}, %{"embed_token" => token}, socket)

      assert updated_socket.assigns.embedded == true
    end

    test "assigns embedded=true when origin matches allowed domain" do
      user = insert(:user)

      profile =
        insert(:profile, user: user, username: "sarah", allowed_embed_domains: ["example.com"])

      socket = build_socket(%{}, %{x_headers: [{"origin", "https://example.com"}]})
      token = Token.sign(profile.username)

      assert {:cont, updated_socket} =
               EmbedAuthHook.on_mount(:default, %{}, %{"embed_token" => token}, socket)

      assert updated_socket.assigns.embedded == true
    end

    test "halts with redirect when origin is not allowed" do
      user = insert(:user)

      profile =
        insert(:profile, user: user, username: "sarah", allowed_embed_domains: ["example.com"])

      socket = build_socket(%{}, %{x_headers: [{"origin", "https://evil.com"}]})
      token = Token.sign(profile.username)

      assert {:halt, updated_socket} =
               EmbedAuthHook.on_mount(:default, %{}, %{"embed_token" => token}, socket)

      assert updated_socket.redirected == {:redirect, %{to: "/", status: 302}}
    end

    test "halts with redirect for expired token" do
      socket = build_socket(%{}, %{x_headers: []})

      expired_token =
        Phoenix.Token.sign(TymeslotWeb.Endpoint, "embed_session", "testuser",
          signed_at: System.system_time(:second) - 22_000
        )

      assert {:halt, updated_socket} =
               EmbedAuthHook.on_mount(:default, %{}, %{"embed_token" => expired_token}, socket)

      assert updated_socket.redirected == {:redirect, %{to: "/", status: 302}}
    end

    test "halts with redirect for tampered token" do
      socket = build_socket(%{}, %{x_headers: []})

      assert {:halt, updated_socket} =
               EmbedAuthHook.on_mount(:default, %{}, %{"embed_token" => "tampered"}, socket)

      assert updated_socket.redirected == {:redirect, %{to: "/", status: 302}}
    end

    test "halts when profile not found for token username" do
      socket = build_socket(%{}, %{x_headers: [{"origin", "https://example.com"}]})
      token = Token.sign("nonexistent_user")

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
  end
end
