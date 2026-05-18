defmodule Tymeslot.Mocks.HTTPClient do
  @moduledoc """
  HTTP client mocks. Default behaviour returns a transport timeout so any code
  path that reaches the HTTP layer (e.g. CalDAV `validate_config`) has a safe
  fallback. Tests needing specific responses should override with `expect/4`.

  See `Tymeslot.TestMocks` for the public API (`setup_http_client_mocks/0`).
  """

  import Mox

  @spec setup() :: term()
  def setup do
    stub(Tymeslot.HTTPClientMock, :request, fn _method, _url, _body, _headers, _opts ->
      {:error, %Mint.TransportError{reason: :timeout}}
    end)

    stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
      {:error, %Mint.TransportError{reason: :timeout}}
    end)
  end
end
