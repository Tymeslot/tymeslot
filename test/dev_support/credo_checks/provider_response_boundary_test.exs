Code.require_file(
  "dev_support/credo_checks/provider_response_boundary.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.ProviderResponseBoundaryTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.ProviderResponseBoundary

  @moduletag :dev_support

  @provider "lib/tymeslot/integrations/video/providers/some_provider.ex"

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  test "flags a video provider binding a response body" do
    """
    defmodule Tymeslot.Integrations.Video.Providers.SomeProvider do
      def handle({:ok, %Req.Response{status: 200, body: body}}), do: Jason.decode(body)
    end
    """
    |> to_source_file(@provider)
    |> run_check(ProviderResponseBoundary)
    |> assert_issue(fn issue -> assert issue.trigger == "%Req.Response{" end)
  end

  test "flags the aliased struct too" do
    """
    defmodule Tymeslot.Integrations.Video.Providers.SomeProvider do
      alias Req.Response
      def handle({:ok, %Response{body: body}}), do: body
    end
    """
    |> to_source_file(@provider)
    |> run_check(ProviderResponseBoundary)
    |> assert_issue(fn issue -> assert issue.trigger == "%Response{" end)
  end

  test "allows a match on the status alone" do
    """
    defmodule Tymeslot.Integrations.Video.Providers.SomeProvider do
      def handle({:ok, %Req.Response{status: 401}}), do: :refresh
    end
    """
    |> to_source_file(@provider)
    |> run_check(ProviderResponseBoundary)
    |> refute_issues()
  end

  test "leaves files outside the video integrations alone" do
    """
    defmodule Tymeslot.Integrations.Calendar.CalDAV.Http do
      def handle({:ok, %Req.Response{body: body}}), do: body
    end
    """
    |> to_source_file("lib/tymeslot/integrations/calendar/caldav/http.ex")
    |> run_check(ProviderResponseBoundary)
    |> refute_issues()
  end

  test "skips an allowed file" do
    """
    defmodule Tymeslot.Integrations.Video.Providers.SomeProvider do
      def handle({:ok, %Req.Response{body: body}}), do: body
    end
    """
    |> to_source_file(@provider)
    |> run_check(ProviderResponseBoundary, allowed: ["some_provider.ex"])
    |> refute_issues()
  end
end
