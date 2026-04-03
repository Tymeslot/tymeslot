defmodule Tymeslot.MockCase do
  @moduledoc """
  Case template for tests that need Mox but not a database connection.

  Sets up Mox context and provides a safe HTTP client fallback so code paths
  that hit the network (e.g., CalDAV `validate_config` → `test_connection`)
  don't crash with `Mox.UnexpectedCallError`.

  Tests that need specific HTTP responses can override the stub with `expect/4`.

  ## Usage

      defmodule MyTest do
        use Tymeslot.MockCase, async: true
        @moduletag :integrations

        test "something" do
          expect(Tymeslot.HTTPClientMock, :request, fn :propfind, _, _, _, _ ->
            {:ok, %Req.Response{status: 207, body: ""}}
          end)

          # ...
        end
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Mox
    end
  end

  setup tags do
    Mox.set_mox_from_context(tags)

    # Safe fallback for any HTTP call — returns a timeout error.
    # Individual tests override with expect/4 when they care about the response.
    Mox.stub(Tymeslot.HTTPClientMock, :request, fn _method, _url, _body, _headers, _opts ->
      {:error, %Mint.TransportError{reason: :timeout}}
    end)

    Mox.stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
      {:error, %Mint.TransportError{reason: :timeout}}
    end)

    :ok
  end
end
