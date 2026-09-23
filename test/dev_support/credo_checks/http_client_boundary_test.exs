Code.require_file(
  "dev_support/credo_checks/http_client_boundary.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.HttpClientBoundaryTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.HttpClientBoundary

  @moduletag :dev_support

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  describe "flagged cases" do
    test "flags Req.post/2" do
      """
      defmodule Tymeslot.Integrations.SomeApi do
        def send(url, body) do
          Req.post(url, json: body)
        end
      end
      """
      |> to_source_file("lib/tymeslot/integrations/some_api.ex")
      |> run_check(HttpClientBoundary)
      |> assert_issue(fn issue -> assert issue.trigger == "Req.post" end)
    end

    test "flags Req.get!/1" do
      """
      defmodule Tymeslot.Integrations.SomeApi do
        def fetch(url) do
          Req.get!(url)
        end
      end
      """
      |> to_source_file("lib/tymeslot/integrations/some_api.ex")
      |> run_check(HttpClientBoundary)
      |> assert_issue(fn issue -> assert issue.trigger == "Req.get!" end)
    end

    test "flags HTTPoison.get/1" do
      """
      defmodule Tymeslot.Integrations.SomeApi do
        def fetch(url) do
          HTTPoison.get(url)
        end
      end
      """
      |> to_source_file("lib/tymeslot/integrations/some_api.ex")
      |> run_check(HttpClientBoundary)
      |> assert_issue(fn issue -> assert issue.trigger == "HTTPoison.get" end)
    end

    test "flags Tesla.get/2" do
      """
      defmodule Tymeslot.Integrations.SomeApi do
        def fetch(client, url) do
          Tesla.get(client, url)
        end
      end
      """
      |> to_source_file("lib/tymeslot/integrations/some_api.ex")
      |> run_check(HttpClientBoundary)
      |> assert_issue(fn issue -> assert issue.trigger == "Tesla.get" end)
    end

    test "flags :httpc.request/1" do
      """
      defmodule Tymeslot.Integrations.SomeApi do
        def fetch(request) do
          :httpc.request(request)
        end
      end
      """
      |> to_source_file("lib/tymeslot/integrations/some_api.ex")
      |> run_check(HttpClientBoundary)
      |> assert_issue(fn issue -> assert issue.trigger == "httpc.request" end)
    end

    test "flags each direct call separately" do
      """
      defmodule Tymeslot.Integrations.SomeApi do
        def fetch(url) do
          Req.get(url)
          Req.post(url, json: %{})
        end
      end
      """
      |> to_source_file("lib/tymeslot/integrations/some_api.ex")
      |> run_check(HttpClientBoundary)
      |> assert_issues(fn issues -> assert length(issues) == 2 end)
    end
  end

  describe "accepted cases" do
    test "accepts Req.Test.stub/2 from lib" do
      """
      defmodule Tymeslot.Integrations.SomeApi do
        def setup_stub do
          Req.Test.stub(Tymeslot.Integrations.SomeApi, fn conn -> conn end)
        end
      end
      """
      |> to_source_file("lib/tymeslot/integrations/some_api.ex")
      |> run_check(HttpClientBoundary)
      |> refute_issues()
    end

    test "accepts a %Req.Response{} pattern match" do
      """
      defmodule Tymeslot.Integrations.SomeApi do
        def handle({:ok, %Req.Response{status: 200, body: body}}), do: body
      end
      """
      |> to_source_file("lib/tymeslot/integrations/some_api.ex")
      |> run_check(HttpClientBoundary)
      |> refute_issues()
    end

    test "accepts the wrapper file itself calling Req.request/1" do
      """
      defmodule Tymeslot.Infrastructure.HTTPClient do
        def request(req_options) do
          Req.request(req_options)
        end
      end
      """
      |> to_source_file("lib/tymeslot/infrastructure/http_client.ex")
      |> run_check(HttpClientBoundary)
      |> refute_issues()
    end

    test "accepts a mix task calling Req.get/1" do
      """
      defmodule Mix.Tasks.Tymeslot.SyncTlds do
        use Mix.Task

        def run(_args) do
          Req.get("https://example.com")
        end
      end
      """
      |> to_source_file("lib/mix/tasks/tymeslot.sync_tlds.ex")
      |> run_check(HttpClientBoundary)
      |> refute_issues()
    end

    test "accepts a normal Config.http_client_module().request(...) call site" do
      """
      defmodule Tymeslot.Integrations.SomeApi do
        alias Tymeslot.Infrastructure.Config

        def fetch(url) do
          Config.http_client_module().request(:get, url, nil, [], [])
        end
      end
      """
      |> to_source_file("lib/tymeslot/integrations/some_api.ex")
      |> run_check(HttpClientBoundary)
      |> refute_issues()
    end

    test "accepts a filename matched by the :allowed param" do
      """
      defmodule Tymeslot.Some.Exception do
        def fetch(url), do: Req.get(url)
      end
      """
      |> to_source_file("lib/tymeslot/some/exception.ex")
      |> run_check(HttpClientBoundary, allowed: ["lib/tymeslot/some/exception.ex"])
      |> refute_issues()
    end

    test "flags the same file when the :allowed param does not match it" do
      """
      defmodule Tymeslot.Some.Exception do
        def fetch(url), do: Req.get(url)
      end
      """
      |> to_source_file("lib/tymeslot/some/exception.ex")
      |> run_check(HttpClientBoundary, allowed: ["lib/tymeslot/other/thing.ex"])
      |> assert_issue()
    end
  end
end
