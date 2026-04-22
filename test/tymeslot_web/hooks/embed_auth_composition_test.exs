defmodule TymeslotWeb.Hooks.EmbedAuthCompositionTest do
  @moduledoc """
  Composition tests for `EmbedAuthHook` exercised via the full HTTP →
  LiveView WebSocket mount.

  The existing `embed_auth_hook_test.exs` unit-tests the hook against
  a hand-built socket for each failure mode (tampered token, expired
  token, missing parent_origin, empty/nil/`["none"]` domain list,
  profile not found, wildcard/www matching). The existing
  `embed_pipeline_test.exs` covers the disconnected (static) half of
  the embed request — CSP headers, token generation, token → session
  flow, and successful static render.

  What neither file covers is the static → connected re-validation
  seam: the hook deliberately defers origin verification on the
  disconnected render (so a signed token with any origin can render
  the page statically) and enforces it only on the WebSocket connect.
  A regression that accidentally checked the origin on the static
  render would still pass every existing assertion — the gap is the
  user journey where an attacker frames the page with an unauthorised
  Referer and the connected mount must catch them.

  Dropped from the plan with rationale:

    * `malformed embed token (corrupted Base64 signature) → halt, no
      exception` — covered at
      `embed_auth_hook_test.exs:112` ("halts with redirect for
      tampered token") and `:121` (same, on disconnected render).
      Both feed the literal string `"tampered"` — a corrupted signature
      and a truncated Base64 reach the same `Token.verify/1` error arm,
      so the existing assertions already pin this behaviour.
  """

  use TymeslotWeb.ConnCase, async: true

  @moduletag :hooks
  @moduletag :security
  @moduletag :live

  import Phoenix.LiveViewTest
  import Plug.Conn
  import Tymeslot.Factory

  describe "static render vs connected render — re-validation seam" do
    test "static render succeeds but connected mount rejects when the embed request Referer is not in the profile's allowlist",
         %{conn: conn} do
      user = insert(:user)

      insert(:profile,
        user: user,
        username: "strictembed",
        allowed_embed_domains: ["trusted.com"],
        booking_theme: "1"
      )

      insert(:meeting_type, user: user, is_active: true)

      # The browser sends its own origin as the Referer when loading
      # an iframe. EmbedTokenPlug signs the embed token with that
      # origin — so a Referer from an unauthorised host produces a
      # token whose signed parent_origin is not in the allowlist.
      conn =
        conn
        |> put_req_header("referer", "https://attacker.com/evil-page")
        |> get(~p"/strictembed?embed=1")

      # Disconnected render succeeds — EmbedAuthHook explicitly defers
      # origin verification to the WebSocket phase. A regression that
      # moved the check earlier would surface here as a non-200.
      assert conn.status == 200

      # Connected mount must reject. `Phoenix.LiveViewTest.live/1`
      # upgrades the given conn to a WebSocket render and propagates
      # `{:halt, redirect(...)}` as an `{:error, {:redirect, _}}`
      # tuple. If the hook failed to re-validate, this would return
      # `{:ok, view, html}` and the attacker would get a live session.
      assert {:error, {:redirect, %{to: "/"}}} = live(conn)
    end

    test "connected mount succeeds when the embed request Referer is in the profile's allowlist",
         %{conn: conn} do
      user = insert(:user)

      insert(:profile,
        user: user,
        username: "trustedembed",
        allowed_embed_domains: ["trusted.com"],
        booking_theme: "1"
      )

      insert(:meeting_type, user: user, is_active: true)

      conn =
        conn
        |> put_req_header("referer", "https://trusted.com/host-page")
        |> get(~p"/trustedembed?embed=1")

      assert conn.status == 200

      # The connected phase re-validates and accepts the signed origin.
      # This is the positive counterpart to the rejection test above —
      # it pins that the re-validation is discriminating (accepts
      # allowlisted origins) rather than rejecting unconditionally.
      assert {:ok, _view, _html} = live(conn)
    end
  end
end
