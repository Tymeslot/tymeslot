defmodule TymeslotWeb.ZoomDeauthControllerTest do
  use TymeslotWeb.ConnCase, async: false
  @moduletag :integrations

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Security.RateLimiter

  @path "/auth/zoom/deauthorize"
  @secret "zoom-deauth-test-secret"
  @client_id "zoom-test-client-id"

  setup do
    RateLimiter.clear_all()

    original = Application.get_env(:tymeslot, :zoom_oauth)

    Application.put_env(
      :tymeslot,
      :zoom_oauth,
      Keyword.merge(original || [], deauth_secret: @secret, client_id: @client_id)
    )

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:tymeslot, :zoom_oauth)
      else
        Application.put_env(:tymeslot, :zoom_oauth, original)
      end
    end)

    :ok
  end

  describe "POST /auth/zoom/deauthorize — signature verification" do
    test "rejects requests with no signature header", %{conn: conn} do
      payload = ~s({"event":"app_deauthorized","payload":{"user_id":"abc"}})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> assign(:raw_body, payload)
        |> post(@path, payload)

      assert %{"error" => "invalid_signature"} = json_response(conn, 401)
    end

    test "rejects requests with a tampered body", %{conn: conn} do
      original = ~s({"event":"app_deauthorized","payload":{"user_id":"abc"}})
      tampered = ~s({"event":"app_deauthorized","payload":{"user_id":"hacked"}})
      timestamp = fresh_timestamp()
      signature = sign(original, timestamp)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-zm-signature", signature)
        |> put_req_header("x-zm-request-timestamp", timestamp)
        |> assign(:raw_body, tampered)
        |> post(@path, tampered)

      assert %{"error" => "invalid_signature"} = json_response(conn, 401)
    end

    test "rejects a correctly-signed request whose timestamp is stale (replay)", %{conn: conn} do
      payload = ~s({"event":"app_deauthorized","payload":{"user_id":"abc"}})
      # Well outside the 300s freshness window — a captured replay.
      timestamp = Integer.to_string(System.system_time(:second) - 3600)
      signature = sign(payload, timestamp)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-zm-signature", signature)
        |> put_req_header("x-zm-request-timestamp", timestamp)
        |> assign(:raw_body, payload)
        |> post(@path, payload)

      assert %{"error" => "invalid_signature"} = json_response(conn, 401)
    end
  end

  describe "POST /auth/zoom/deauthorize — URL validation challenge" do
    test "responds with HMAC of plainToken when signature is valid", %{conn: conn} do
      plain_token = "abc123"

      payload =
        Jason.encode!(%{event: "endpoint.url_validation", payload: %{plainToken: plain_token}})

      timestamp = fresh_timestamp()
      signature = sign(payload, timestamp)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-zm-signature", signature)
        |> put_req_header("x-zm-request-timestamp", timestamp)
        |> assign(:raw_body, payload)
        |> post(@path, payload)

      expected_encrypted =
        :hmac
        |> :crypto.mac(:sha256, @secret, plain_token)
        |> Base.encode16(case: :lower)

      assert %{"plainToken" => ^plain_token, "encryptedToken" => ^expected_encrypted} =
               json_response(conn, 200)
    end
  end

  describe "POST /auth/zoom/deauthorize — app_deauthorized event" do
    test "removes every Zoom integration referencing the deauthorised account", %{conn: conn} do
      zoom_user_id = "z9-deauthorised-user"

      integration =
        insert(:video_integration,
          provider: "zoom",
          provider_account_id: zoom_user_id,
          is_active: true
        )

      payload =
        Jason.encode!(%{
          event: "app_deauthorized",
          payload: %{
            user_id: zoom_user_id,
            account_id: "acct-123",
            client_id: @client_id,
            deauthorization_time: "2026-05-08T00:00:00Z",
            signature: "ignored"
          }
        })

      timestamp = fresh_timestamp()
      signature = sign(payload, timestamp)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-zm-signature", signature)
        |> put_req_header("x-zm-request-timestamp", timestamp)
        |> assign(:raw_body, payload)
        |> post(@path, payload)

      assert %{"status" => "ok"} = json_response(conn, 200)
      assert {:error, :not_found} = VideoIntegrationQueries.get(integration.id)
    end

    test "is idempotent for unknown Zoom accounts", %{conn: conn} do
      payload =
        Jason.encode!(%{
          event: "app_deauthorized",
          payload: %{
            user_id: "never-seen-this-account",
            account_id: "acct-999",
            client_id: @client_id,
            deauthorization_time: "2026-05-08T00:00:00Z",
            signature: "ignored"
          }
        })

      timestamp = fresh_timestamp()
      signature = sign(payload, timestamp)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-zm-signature", signature)
        |> put_req_header("x-zm-request-timestamp", timestamp)
        |> assign(:raw_body, payload)
        |> post(@path, payload)

      assert %{"status" => "ok"} = json_response(conn, 200)
    end

    test "does not remove integrations when the client_id does not match this app", %{conn: conn} do
      zoom_user_id = "z9-other-app-user"

      integration =
        insert(:video_integration,
          provider: "zoom",
          provider_account_id: zoom_user_id,
          is_active: true
        )

      payload =
        Jason.encode!(%{
          event: "app_deauthorized",
          payload: %{
            user_id: zoom_user_id,
            account_id: "acct-other",
            client_id: "some-other-app-client-id",
            deauthorization_time: "2026-05-08T00:00:00Z",
            signature: "ignored"
          }
        })

      timestamp = fresh_timestamp()
      signature = sign(payload, timestamp)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-zm-signature", signature)
        |> put_req_header("x-zm-request-timestamp", timestamp)
        |> assign(:raw_body, payload)
        |> post(@path, payload)

      assert %{"status" => "ok"} = json_response(conn, 200)
      assert {:ok, _row} = VideoIntegrationQueries.get(integration.id)
    end
  end

  defp sign(body, timestamp) do
    digest =
      :hmac
      |> :crypto.mac(:sha256, @secret, "v0:" <> timestamp <> ":" <> body)
      |> Base.encode16(case: :lower)

    "v0=" <> digest
  end

  # A current Unix-epoch-seconds timestamp, inside the controller's freshness
  # window, so signature verification is exercised rather than the freshness
  # guard.
  defp fresh_timestamp, do: Integer.to_string(System.system_time(:second))
end
