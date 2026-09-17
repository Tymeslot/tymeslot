defmodule Tymeslot.Integrations.Calendar.Providers.CaldavClientRedactionTest do
  @moduledoc """
  The CalDAV client carries the integration's decrypted password, and it is
  handed to supervised tasks whose crash reports print their arguments
  verbatim. `CalendarIntegrationSchema` marks the field `redact: true`, but
  that protects the schema struct, not a plain map the value was copied into —
  so the client has to refuse to print it itself.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.CalDAV.Client
  alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon

  @password "0E5bY4becyOM3PAF"

  defp client do
    CaldavCommon.build_client(
      %{
        base_url: "https://sync.example.com",
        username: "LR07587",
        password: @password,
        calendar_paths: ["/calendars/LR07587/personal/"]
      },
      provider: :caldav
    )
  end

  describe "build_client/2" do
    test "builds a Client struct rather than a bare map" do
      assert %Client{} = client()
    end

    test "keeps the password reachable for the request that needs it" do
      # Redaction that also hid the value from the Basic auth header would be
      # a broken client, not a safe one.
      assert client().password == @password
    end
  end

  describe "inspecting a client" do
    test "never prints the password" do
      refute inspect(client()) =~ @password
    end

    test "prints the fields that make a crash report worth reading" do
      inspected = inspect(client())

      assert inspected =~ "sync.example.com"
      assert inspected =~ "LR07587"
      assert inspected =~ ":caldav"
    end

    test "hides the password when the client is nested inside another term" do
      # The shape that leaked: the client sits inside the adapter client,
      # inside a task's argument list.
      args = [:some_fun, [%{client: client(), provider_type: :caldav}]]

      refute inspect(args, limit: :infinity) =~ @password
    end
  end
end
