defmodule Tymeslot.Integrations.Video.Providers.NextcloudTalkRefusalsTest do
  @moduledoc """
  A Nextcloud Talk server whose own settings refuse the conversations a booking
  needs: each refusal at creation carries its own code, and a connection test
  someone asked for refuses such a server up front where Talk's capabilities
  announce it. The bodies are the ones a Talk 25.0.0 server sent with each
  setting switched on; a Talk 24.0.5 server's source sends them identically.
  """

  use ExUnit.Case, async: true

  @moduletag :integrations
  @moduletag :video

  import Mox

  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Video.EventDetails
  alias Tymeslot.Integrations.Video.Providers.NextcloudTalkProvider

  setup :verify_on_exit!

  @start ~U[2026-10-01 14:00:00Z]

  @config %{
    base_url: "https://cloud.example.com",
    client_id: "organiser",
    client_secret: "Abcde-Fghij-Klmno-Pqrst-Uvwxy",
    needs_reauth: false
  }

  describe "create_meeting_room/1" do
    # The refusals a Talk 25.0.0 server sent with each setting switched on, and
    # which a Talk 24.0.5 server's source sends identically. Each one repeats
    # on every attempt, so it is a configuration error with its own code.
    for {setting, status, body, code} <- [
          {"conversation creation limited to a group (start_conversations)", 403,
           ~s({"ocs":{"meta":{"status":"failure","statuscode":403,"message":""},"data":{"error":"permissions"}}}),
           :conversation_creation_restricted},
          {"Talk limited to a group (allowed_groups)", 403,
           ~s({"ocs":{"meta":{"status":"failure","statuscode":403,"message":"Can not use Talk"},"data":[]}}),
           :talk_not_allowed},
          {"passwords enforced on public conversations (force_passwords)", 400,
           ~s({"ocs":{"meta":{"status":"failure","statuscode":400,"message":""},"data":{"error":"password","message":"Password needs to be set"}}}),
           :password_required},
          {"a refusal of anything else", 400,
           ~s({"ocs":{"meta":{"status":"failure","statuscode":400,"message":""},"data":{"error":"lobby-timer"}}}),
           :conversation_refused},
          {"a refusal without an error key", 400,
           ~s({"ocs":{"meta":{"status":"failure","statuscode":400,"message":""},"data":[]}}),
           :conversation_refused},
          {"Talk missing", 404, "", :talk_not_found}
        ] do
      test "a server with #{setting} is a configuration error coded #{code}" do
        expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
          {:ok, %Req.Response{status: unquote(status), body: unquote(body)}}
        end)

        assert {:error, {:configuration_error, unquote(code)}} =
                 NextcloudTalkProvider.create_meeting_room(with_event(@config))
      end
    end

    test "a Talk limited to a group already refuses the lookup for an earlier conversation" do
      expect(HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 403,
           body:
             ~s({"ocs":{"meta":{"status":"failure","statuscode":403,"message":"Can not use Talk"},"data":[]}})
         }}
      end)

      config = Map.put(with_event(@config), :meeting_id, "meeting-1")

      assert {:error, {:configuration_error, :talk_not_allowed}} =
               NextcloudTalkProvider.create_meeting_room(config)
    end

    test "a redirect is a configuration error" do
      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 302,
           headers: %{"location" => ["https://login.example.com/"]},
           body: ""
         }}
      end)

      assert {:error, {:configuration_error, :redirected}} =
               NextcloudTalkProvider.create_meeting_room(with_event(@config))
    end
  end

  describe "perform_connection_test/1" do
    for {setting, conversations, expected} <- [
          {"may not create conversations", %{"can-create" => false, "force-passwords" => false},
           "create conversations"},
          {"must set a password on public conversations",
           %{"can-create" => true, "force-passwords" => true}, "password requirement"}
        ] do
      test "refuses an account that #{setting}, saying how to allow it" do
        expect(HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
          capabilities(talk_25(unquote(Macro.escape(conversations))))
        end)

        assert {:error, {:not_permitted, message}} =
                 NextcloudTalkProvider.perform_connection_test(@config)

        assert message =~ unquote(expected)
      end

      test "the background health check passes an account that #{setting}" do
        expect(HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
          capabilities(talk_25(unquote(Macro.escape(conversations))))
        end)

        config = Map.put(@config, :connection_test_scope, :background)
        assert {:ok, _message} = NextcloudTalkProvider.perform_connection_test(config)
      end
    end

    test "passes a Talk that announces neither right, as older servers may not" do
      expect(HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        capabilities(%{
          "version" => "24.0.5",
          "features" => ["conversation-creation-all"],
          "config" => %{"conversations" => %{"list-style" => "two-lines"}}
        })
      end)

      assert {:ok, _message} = NextcloudTalkProvider.perform_connection_test(@config)
    end

    test "passes an account that may create conversations without a password" do
      expect(HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        capabilities(talk_25(%{"can-create" => true, "force-passwords" => false}))
      end)

      assert {:ok, message} = NextcloudTalkProvider.perform_connection_test(@config)
      assert message =~ "25.0.0"
    end
  end

  defp with_event(config) do
    Map.put(config, :event_details, %EventDetails{
      summary: "Intro call",
      start_time: @start,
      end_time: DateTime.add(@start, 1800, :second)
    })
  end

  # The part of a Talk 25.0.0 server's capabilities the connection test reads.
  defp talk_25(conversations) do
    %{
      "version" => "25.0.0",
      "features" => ["conversation-creation-all"],
      "config" => %{
        "conversations" =>
          Map.merge(%{"list-style" => "two-lines", "description-length" => 2000}, conversations)
      }
    }
  end

  defp capabilities(spreed) do
    body =
      Jason.encode!(%{
        "ocs" => %{
          "meta" => %{"status" => "ok"},
          "data" => %{"capabilities" => %{"spreed" => spreed}}
        }
      })

    {:ok, %Req.Response{status: 200, body: body}}
  end
end
