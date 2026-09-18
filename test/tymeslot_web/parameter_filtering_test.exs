defmodule TymeslotWeb.ParameterFilteringTest do
  @moduledoc """
  Proves that `config :phoenix, :filter_parameters` covers every parameter name
  this application posts whose value is a credential.

  Each test drives a real request through the endpoint and asserts on what the
  request logger wrote. Phoenix and LiveView render their `Parameters:` line
  through the same filter, so a name that survives here is a name that reaches
  the log verbatim from a connect form too.

  Production pins the level to `:info`, where the line is not emitted at all,
  but dev runs at `:debug` and nothing stops a deployment from raising the
  level; the filter is what has to hold, not the level.
  """

  # async: false — these tests lower the primary Logger level, which is global
  # and would otherwise leak into concurrently running tests.
  use TymeslotWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  @moduletag :security

  @secret "s3cr3t-value-that-must-not-be-logged"

  # One entry per form in the application that submits a credential, in the
  # shape its parameters arrive in. Add a row here when a new connect form is
  # added.
  @credential_params [
    {"the Nextcloud Talk and Jitsi connect forms",
     %{"integration" => %{"client_secret" => @secret}}},
    {"the MiroTalk connect form", %{"integration" => %{"api_key" => @secret}}},
    {"the CalDAV connect form", %{"integration" => %{"password" => @secret}}},
    {"the CalDAV reconnect dialog", %{"reconnect" => %{"password" => @secret}}},
    {"the Slack connect form", %{"slack" => %{"webhook_url" => @secret}}},
    {"the Telegram connect form", %{"telegram" => %{"bot_token" => @secret}}},
    {"the login form", %{"user" => %{"password" => @secret}}},
    {"the email change form", %{"email_form" => %{"current_password" => @secret}}},
    {"the password change form",
     %{
       "password_form" => %{
         "current_password" => @secret,
         "new_password" => @secret,
         "new_password_confirmation" => @secret
       }
     }},
    {"the password reset form", %{"token" => @secret, "password" => @secret}},
    {"an OAuth token exchange", %{"access_token" => @secret, "refresh_token" => @secret}}
  ]

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)
  end

  describe "the request log" do
    for {form, params} <- @credential_params do
      test "redacts the credential submitted by #{form}", %{conn: conn} do
        log = request_log(conn, unquote(Macro.escape(params)))

        assert log =~ "Parameters:"
        assert log =~ "[FILTERED]"
        refute log =~ @secret
      end
    end

    test "leaves parameters that are not credentials alone", %{conn: conn} do
      log =
        request_log(conn, %{
          "integration" => %{
            "name" => "My Nextcloud Talk",
            "base_url" => "https://cloud.example.com",
            "client_id" => "organiser",
            "provider" => "nextcloud_talk"
          }
        })

      assert log =~ "My Nextcloud Talk"
      assert log =~ "https://cloud.example.com"
      assert log =~ "organiser"
      refute log =~ "[FILTERED]"
    end
  end

  defp request_log(conn, params) do
    capture_log(fn ->
      conn
      |> get(~p"/healthcheck", params)
      |> response(200)
    end)
  end
end
