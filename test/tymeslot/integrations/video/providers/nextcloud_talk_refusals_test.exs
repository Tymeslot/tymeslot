defmodule Tymeslot.Integrations.Video.Providers.NextcloudTalkRefusalsTest do
  @moduledoc """
  A Nextcloud Talk server whose own settings refuse the conversations a booking
  needs: each refusal at creation carries its own code. The bodies are the ones a Talk 25.0.0 server sent with each
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

  defp with_event(config) do
    Map.put(config, :event_details, %EventDetails{
      summary: "Intro call",
      start_time: @start,
      end_time: DateTime.add(@start, 1800, :second)
    })
  end
end
