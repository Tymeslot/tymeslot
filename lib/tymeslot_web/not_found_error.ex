defmodule TymeslotWeb.NotFoundError do
  @moduledoc """
  Raised when a request resolves a route but the underlying resource does not
  exist (e.g. an unknown organizer username).

  Carries `plug_status: 404` so `Plug.Exception` renders a real `404 Not Found`.
  This is the idiomatic way to return a 404 from a LiveView: raising in `mount`
  is handled by the normal Plug error pipeline on the dead render, instead of a
  soft-404 redirect to `/` that crawlers read as a valid page.
  """
  defexception [:message, plug_status: 404]
end
