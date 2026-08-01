defmodule TymeslotWeb.Plugs.WebhookBodyCachePlugTest do
  @moduledoc """
  Covers the :body_reader plug that caches raw request bodies for
  webhook signature verification. Stripe HMAC verification (and any
  other future webhook with a signed payload) can only validate
  against the byte-exact request body — Plug.Parsers consumes it
  before the controller runs, so the raw bytes must be assigned to
  `conn.assigns.raw_body` at parse time or signature checks see an
  empty string and accept forged payloads.
  """

  # async: false — the :webhook_paths override test mutates application
  # env, so concurrent tests would race on the config read.
  use ExUnit.Case, async: false

  @moduletag :plugs

  alias Plug.Test, as: PlugTest
  alias TymeslotWeb.Plugs.WebhookBodyCachePlug

  defp build_conn_with_body(path, body) do
    # Phoenix.ConnTest.build_conn builds a conn with an adapter that
    # hands the body over via Conn.read_body/2. We build it manually
    # here because we don't need the whole TymeslotWeb router — just
    # the plug.
    PlugTest.conn(:post, path, body)
  end

  describe "read_body/2 — webhook paths" do
    test "assigns :raw_body when the request path matches a configured webhook path" do
      payload = ~s({"type":"checkout.session.completed"})
      conn = build_conn_with_body("/webhooks/stripe", payload)

      assert {:ok, ^payload, conn} = WebhookBodyCachePlug.read_body(conn, [])
      assert conn.assigns[:raw_body] == payload
    end

    test "does not assign :raw_body for non-webhook paths" do
      payload = ~s({"anything":"at all"})
      conn = build_conn_with_body("/dashboard/settings", payload)

      assert {:ok, ^payload, conn} = WebhookBodyCachePlug.read_body(conn, [])
      refute Map.has_key?(conn.assigns, :raw_body)
    end

    test "respects the :webhook_paths application config override" do
      # Overriding the config is the self-host seam — every Core
      # deployment can declare its own set of signed webhook routes.
      original = Application.get_env(:tymeslot, :webhook_paths)
      Application.put_env(:tymeslot, :webhook_paths, ["/api/webhook/custom"])

      on_exit(fn ->
        if original == nil do
          Application.delete_env(:tymeslot, :webhook_paths)
        else
          Application.put_env(:tymeslot, :webhook_paths, original)
        end
      end)

      payload = "signed-by-custom-provider"
      conn = build_conn_with_body("/api/webhook/custom", payload)

      assert {:ok, ^payload, conn} = WebhookBodyCachePlug.read_body(conn, [])
      assert conn.assigns[:raw_body] == payload

      # The stripe path is no longer cached under the override.
      default_conn = build_conn_with_body("/webhooks/stripe", payload)
      assert {:ok, ^payload, default_conn} = WebhookBodyCachePlug.read_body(default_conn, [])
      refute Map.has_key?(default_conn.assigns, :raw_body)
    end
  end

  describe "read_body/2 — error propagation" do
    test "propagates a {:more, _, _} read_body result unchanged and does not assign :raw_body" do
      # A truncated body surfaces as `{:more, partial, conn}` from
      # `Plug.Conn.read_body`. The plug must pass it straight through —
      # Plug.Parsers relies on the exact shape to drive chunked reads.
      # It must also NOT pre-assign `:raw_body` from a partial chunk, or
      # Stripe signature verification would compare the signature against
      # the wrong bytes.
      conn = build_conn_with_body("/webhooks/stripe", "abcdefgh")

      # Length 1 forces Plug.Test's in-memory adapter to return {:more, ...}.
      assert {:more, partial, returned_conn} =
               WebhookBodyCachePlug.read_body(conn, length: 1)

      assert partial == "a"
      refute Map.has_key?(returned_conn.assigns, :raw_body)
    end
  end
end
